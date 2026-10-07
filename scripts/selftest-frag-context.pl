#!/usr/bin/perl
# Regression for frag-context certification and for the two marker branches'
# claim rules.
#
# WHY THIS RUNS THE SHIPPED BLOCK INSTEAD OF MIRRORING IT. The defect being
# guarded is that an absent or blank property numifies to a value that is legal
# for its column, so nothing errors and every count still looks plausible. A
# harness that re-implemented the check would pass against a reverted daemon.
# The payload block is lifted out of hlstats.pl by marker and executed, so a
# revert fails here.
#
#   perl scripts/selftest-frag-context.pl        # exit 0 = pass
use strict;
use warnings;
use Test::More;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';
my $MIGRATION20 = $SCRIPT_DIR . '../sql/migrate_020_frag_context_certified.sql';
my $MIGRATION19 = $SCRIPT_DIR . '../sql/migrate_019_clear_uncertified_frag_context.sql';

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close($fh);
    return $text;
}

sub between_markers {
    my ($source, $begin, $end) = @_;
    my $begin_at = index($source, $begin);
    die "missing source marker: $begin" if $begin_at < 0;
    my $code_at = index($source, "\n", $begin_at) + 1;
    my $end_at = index($source, $end, $code_at);
    die "missing source marker: $end" if $end_at < 0;
    return substr($source, $code_at, $end_at - $code_at);
}

my $source = slurp($SRC);
my $payload = between_markers($source,
    '# BEGIN KTP FRAG CONTEXT PAYLOAD',
    '# END KTP FRAG CONTEXT PAYLOAD');

our (%ev_properties_hash, $ktp_actor_player_id, $ktp_victim_player_id, @logged);
$ktp_actor_player_id = 9001;
$ktp_victim_player_id = 9002;
sub printEvent { push(@logged, join(' ', @_[0, 1])); }

# Runs the shipped block over one property set and hands back what it decided.
sub resolve {
    my (%properties) = @_;
    %ev_properties_hash = %properties;
    @logged = ();
    my $out = eval "no strict 'vars';\n$payload\n"
        . '+{ context => {%fc_context}, unusable => [@fc_unusable],'
        . '   certified => $fc_certified };';
    die "cannot run shipped frag-context payload: $@" unless $out;
    return $out;
}

my %COMPLETE = (
    headshot => '1', k_prone => '0', v_prone => '0', k_scope => '1',
    v_scope => '0', k_clip => '5', k_ammo => '40', v_clip => '8',
    v_ammo => '24', is_last_flag_defense => '0',
);

# --- what the current producer emits on every kill ---------------------------
my $complete = resolve(%COMPLETE);
is($complete->{certified}, 1, 'a complete producer payload certifies');
is_deeply($complete->{unusable}, [], 'a complete payload reports nothing unusable');
is_deeply($complete->{context},
    { headshot => 1, k_prone => 0, v_prone => 0, k_scope => 1, v_scope => 0,
      k_clip => 5, k_ammo => 40, v_clip => 8, v_ammo => 24,
      is_last_flag_defense => 0 },
    'every context property survives the round trip as an integer');
is(scalar(@logged), 0, 'a clean payload is silent');

# --- the defect this file exists for -----------------------------------------
# getProperties yields '' for (k_prone ""), and '' numifies to 0, which is
# "standing" -- a legal reading indistinguishable from a measurement.
my $blank = resolve(%COMPLETE, k_prone => '');
is($blank->{context}{k_prone}, 0, 'a blank property still lands on the column default');
is($blank->{certified}, 0, 'but a blank property withholds certification');
like($blank->{unusable}[0], qr/^k_prone=/, 'the blank property is named');
is(scalar(@logged), 1, 'an unusable property is reported, not swallowed');
like($logged[0], qr/KTP_BAD_PROPERTY/, 'it is reported as a bad property');

my %missing_clip = map { $_ => $COMPLETE{$_} }
    grep { $_ ne 'k_clip' } keys %COMPLETE;
my $absent = resolve(%missing_clip);
is($absent->{context}{k_clip}, -1, 'an absent clip falls back to the read-failed sentinel');
is($absent->{certified}, 0, 'an absent property withholds certification');
like($absent->{unusable}[0], qr/k_clip=<absent>/, 'absent is distinguished from blank');

for my $bad ('yes', '1.5', '-', ' 1') {
    my $got = resolve(%COMPLETE, is_last_flag_defense => $bad);
    is($got->{certified}, 0, "a non-integer '$bad' withholds certification");
    is($got->{context}{is_last_flag_defense}, 0, "'$bad' is not stored as a measurement");
}

# --- values that are legal and must NOT be rejected --------------------------
# -1 is the producer's own "the read failed" reading for clip and ammo, so it is
# a measurement and certifies; migration 005 says so explicitly.
my $sentinel = resolve(%COMPLETE, k_clip => '-1', k_ammo => '-1');
is($sentinel->{certified}, 1, 'an explicit -1 clip reading is a measurement, not a fault');
is($sentinel->{context}{k_clip}, -1, 'the sentinel is stored as sent');

# dod_get_pronestate is a raw state, not a bool, and real traffic carries values
# above the 0/1/2 migration 005 lists -- bound it to the column, not to that list.
my $prone = resolve(%COMPLETE, k_prone => '13');
is($prone->{certified}, 1, 'a raw pronestate beyond the documented set still certifies');
is($prone->{context}{k_prone}, 13, 'the raw pronestate is kept, not coerced to a bool');

# --- out of column range -----------------------------------------------------
my $overflow = resolve(%COMPLETE, k_ammo => '99999');
is($overflow->{certified}, 0, 'a value the column cannot hold withholds certification');
is($overflow->{context}{k_ammo}, -1, 'and is not sent to MySQL to abort the UPDATE');

# --- the SQL the two branches emit -------------------------------------------
my ($headshot_branch) = ($source =~
    /if \(\$ev_obj_a eq "headshot_kill"\) \{(.*?)\n\s*\} elsif \(\$ev_obj_a eq "frag_context"\)/s);
ok(defined($headshot_branch), 'headshot_kill branch is present');
unlike($headshot_branch, qr/frag_context_(?:recorded|certified) = 1/,
    'headshot_kill certifies nothing -- it collects no context');
like($headshot_branch, qr/ORDER BY id ASC/,
    'headshot_kill stays FIFO -- its emitter buffers the marker, so the newest '
    . 'unclaimed frag is routinely a later kill');
like($headshot_branch, qr/AND headshot = 0/,
    'headshot_kill keeps its own claim guard');

my ($frag_branch) = ($source =~
    /elsif \(\$ev_obj_a eq "frag_context"\) \{(.*?)\n\s*\} elsif \(\$ev_obj_a eq "damage"\)/s);
ok(defined($frag_branch), 'frag_context branch is present');
like($frag_branch, qr/frag_context_recorded = 1,\s*\r?\n\s*frag_context_certified = "\.\$fc_certified\./,
    'frag_context always claims, and certifies separately');
like($frag_branch, qr/AND frag_context_recorded = 0/,
    'the claim guard, not the certification, is what makes correlation exactly-once');
unlike($frag_branch, qr/AND frag_context_certified = 0/,
    'certification must not gate the claim, or a partial payload becomes re-claimable');

# --- the weapon clause -------------------------------------------------------
# Runs the shipped block, same reason as the payload above: the failure mode is
# a clause that is merely too strict, which no count makes obvious.
my $weapon_block = between_markers($source,
    '# BEGIN KTP FRAG WEAPON CLAUSE',
    '# END KTP FRAG WEAPON CLAUSE');
our $fc_weapon;
sub quoteSQL { my ($v) = @_; $v =~ s/'/\\'/g; return $v; }
sub weapon_clause {
    ($fc_weapon) = @_;
    my $clause = eval "no strict 'vars';\n$weapon_block\n" . '$fc_weapon_where;';
    die "cannot run shipped weapon clause: $@" if $@;
    return $clause;
}

is(weapon_clause('kar'), "AND weapon IN ('kar') ",
    'an unaliased weapon is matched exactly');
is(weapon_clause('bayonet'), "AND weapon IN ('bayonet', 'kar') ",
    'a documented alternate-fire weapon also accepts its stock base weapon');
# DODX weaponData[0] is labelled "mortar" and both death paths fall back to
# weapon index 0 when they cannot resolve one, so "mortar" on the wire means
# "unknown", not a mortar. hlstats_Events_Frags has never held a weapon='mortar'
# row, so keeping the clause could only ever reject the kill.
is(weapon_clause('mortar'), '',
    'the unresolved-weapon label drops the clause instead of failing on it');
like($frag_branch, qr/AND victimId = "\.int\(\$ktp_victim_player_id\)\."\r?\n\s*\$fc_weapon_where/,
    'the UPDATE takes the weapon clause from the variable, not inline');

# --- the producer join window ------------------------------------------------
# eventTime is daemon receipt time; an exact-second join loses every kill whose
# receipt lands in the neighboring second (28.4% of the Tier-2 corpus --
# FRAG_CONTEXT_COVERAGE_TRIAGE_20260906). The window is [epoch-2, epoch+2),
# nearest row to the producer epoch first. It was [epoch-1, epoch+2) until
# 2026-09-25: measured drift on rows that matched is almost all negative
# (delta -1: 7,107, 0: 30,108, +1: 269), so the tight edge was the wrong one.
like($frag_branch,
    qr/FROM_UNIXTIME\("\.\(\$fc_event_epoch - 2\)\."\)/,
    'producer join window opens two seconds early -- the drift is negative');
like($frag_branch,
    qr/FROM_UNIXTIME\("\.\(\$fc_event_epoch \+ 2\)\."\)/,
    'and closes after epoch+1, half-open');
like($frag_branch,
    qr/ABS\(UNIX_TIMESTAMP\(eventTime\) - "\.\$fc_event_epoch\."\) ASC, id ASC/,
    'the nearest receipt second to the producer epoch wins, id breaks ties');
like($frag_branch,
    qr/\$fc_match_description = "legacy receipt window";\s*\r?\n\s*\$fc_order_by = "id ASC";/,
    'the legacy receipt-window path stays FIFO');
# The join no longer depends on the match context. The producer clock columns
# must still, or an untracked kill is stamped with a match it never had.
like($frag_branch,
    qr/if \(\$fc_context_error eq ""\) \{\s*\r?\n\s*\$fc_clock_sql = /,
    'producer clock columns are written only for a resolved match context');

my $trailing_newline = resolve(%COMPLETE, k_ammo => "1" . chr(10));
is($trailing_newline->{certified}, 0,
    'a trailing newline is rejected -- the $ anchor would have allowed one');

# A revert to the bare defined-or defaults is the failure mode this file guards.
unlike($frag_branch, qr/\$ev_properties_hash\{"(?:k_prone|k_clip|is_last_flag_defense)"\}\s*\/\//,
    'context properties are validated rather than defaulted with //');

# --- the join keys on the kill's log second, not when the daemon read it ----
# UseTimestamp is off, so eventTime is the daemon's processing time. In a flush
# backlog it trails the logged kill by seconds (a kill logged at E lands at E+4)
# and the producer window misses it. The shipped index and time clause run here
# against an in-memory table; the clause interpreter dies on any SQL it does not
# know, so a clause it cannot evaluate cannot pass by being ignored.
my $recent_block = between_markers($source,
    '# BEGIN KTP RECENT FRAGS', '# END KTP RECENT FRAGS');
my $time_block = between_markers($source,
    '# BEGIN KTP FRAG TIME CLAUSE', '# END KTP FRAG TIME CLAUSE');
eval "no strict 'vars';\n$recent_block\n1;" or die "cannot load recent-frags block: $@";

our (%g_ktpRecentFrags, %g_ktpRecentFragsSwept, %g_servers, $s_addr);
our ($fc_seen, $fc_seen_offset, $fc_context_error, $ev_unixtime);
our ($fc_time_where, $fc_match_description, $fc_order_by);
$s_addr = '10.0.0.1:27015';
%g_servers = ($s_addr => { id => 7 });
my (@table, $next_id, @selects);

sub reset_world {
    %g_ktpRecentFrags = (); %g_ktpRecentFragsSwept = ();
    @table = (); $next_id = 100; @selects = ();
}

# What doEvent_Frag does for one stock "killed" line: queue the row stamped with
# the processing second, and note it with the second the line was logged.
sub stock_kill {
    my (%k) = @_;
    my $row = { id => $next_id++, serverId => $k{server} // 7, killerId => $k{killer},
        victimId => $k{victim}, weapon => $k{weapon}, eventTime => $k{read_at}, claimed => 0 };
    push(@table, $row);
    main::ktpNoteRecordedFrag($row->{serverId}, $k{killer}, $k{victim}, $k{weapon},
        $k{logged_at}, $k{read_at});
    return $row->{id};
}

sub rows_where {
    my ($sql) = @_;
    my @rows = @table;
    my $rest = $sql;
    while ($rest =~ s/\b(serverId|killerId|victimId|id) = (\d+)//) {
        my ($col, $v) = ($1, $2);
        @rows = grep { $_->{$col} == $v } @rows;
    }
    while ($rest =~ s/\bweapon IN \(([^)]*)\)//) {
        my %ok = map { my $w = $_; $w =~ s/^\s*'|'\s*$//g; ($w => 1) } split(/,/, $1);
        @rows = grep { $ok{$_->{weapon}} } @rows;
    }
    @rows = grep { !$_->{claimed} } @rows if ($rest =~ s/\bfrag_context_recorded = 0//);
    @rows = () if ($rest =~ s/\b1 = 0//);
    while ($rest =~ s/\beventTime (>=|<|=) FROM_UNIXTIME\((-?\d+)\)//) {
        my ($op, $t) = ($1, $2);
        @rows = grep { $op eq '>=' ? $_->{eventTime} >= $t
            : $op eq '<' ? $_->{eventTime} < $t : $_->{eventTime} == $t } @rows;
    }
    $rest =~ s/\b(?:AND|WHERE)\b|\s+//g;
    die "clause interpreter does not understand: '$rest' in [$sql]" if ($rest ne '');
    return @rows;
}

sub ordered {
    my ($order, @rows) = @_;
    return sort { $a->{id} <=> $b->{id} } @rows if ($order eq 'id ASC');
    if ($order =~ /^ABS\(UNIX_TIMESTAMP\(eventTime\) - (-?\d+)\) ASC, id ASC$/) {
        my $e = $1;
        return sort { abs($a->{eventTime} - $e) <=> abs($b->{eventTime} - $e)
            || $a->{id} <=> $b->{id} } @rows;
    }
    die "unknown ORDER BY: $order";
}

{
    package FakeSth;
    sub new { my ($c, @r) = @_; return bless { rows => [@r] }, $c; }
    sub fetchrow_array { my ($s) = @_; my $r = shift(@{$s->{rows}}); return defined($r) ? ($r) : (); }
    sub finish { 1 }
}
sub doQuery {
    my ($sql) = @_;
    push(@selects, $sql);
    my ($where, $order, $off) = ($sql =~
        /WHERE(.*)ORDER BY\s+(.*?)\s+LIMIT\s+(\d+),\s*1/s) or die "unexpected SELECT: $sql";
    my @rows = ordered($order, rows_where($where));
    return FakeSth->new(defined($rows[$off]) ? $rows[$off]{id} : ());
}

# One frag_context marker through the shipped weapon and time clauses, then the
# UPDATE's own WHERE shape. Returns the claimed row id, or undef.
sub marker {
    my (%m) = @_;
    $fc_weapon = $m{weapon};
    ($ktp_actor_player_id, $ktp_victim_player_id) = ($m{killer}, $m{victim});
    %ev_properties_hash = defined($m{epoch}) ? (event_epoch => $m{epoch}) : ();
    # "" is a match context the daemon resolved; anything else is untracked.
    $fc_context_error = exists($m{context_error}) ? $m{context_error} : "";
    $ev_unixtime = defined($m{read_at}) ? $m{read_at} : $m{epoch};
    ($fc_seen, $fc_seen_offset) = (undef, undef);
    my $where = eval "no strict 'vars';\n$weapon_block\n$time_block\n"
        . '"serverId = 7 AND killerId = $ktp_actor_player_id AND victimId = '
        . '$ktp_victim_player_id $fc_weapon_where AND frag_context_recorded = 0 $fc_time_where";';
    die "cannot run shipped time clause: $@" unless defined($where);
    my ($row) = ordered($fc_order_by, rows_where($where));
    return undef unless $row;
    $row->{claimed} = 1;
    $fc_seen->{claimed} = 1 if ref($fc_seen);
    return $row->{id};
}

my $E = 1_791_000_000;

reset_world();
my $on_time = stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E, read_at => $E);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E), $on_time,
    'an on-time frag still matches');

reset_world();
my $late = stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E, read_at => $E + 4);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E), $late,
    'a frag the daemon read four seconds late matches -- the producer window alone misses it');

reset_world();
my $late_alias = stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E, read_at => $E + 6);
is(marker(killer => 1, victim => 2, weapon => 'bayonet', epoch => $E + 1), $late_alias,
    'the weapon alias and a one-second log/epoch boundary still find a late row');

# Same killer, victim and weapon twice, both read in one backlogged second that
# sits inside the producer window of the later kill. The earlier kill's marker is
# lost; nearest-row-then-id would hand its row to the later marker.
reset_world();
my $first = stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E, read_at => $E + 4);
my $second = stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E + 3, read_at => $E + 4);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E + 3), $second,
    'an ambiguous same-second pair attaches the later marker to the later kill');
ok(!(grep { $_->{id} == $first && $_->{claimed} } @table),
    'and leaves the earlier kill unclaimed rather than stealing it');
is(scalar(@selects), 1, 'skipping an unclaimed earlier row costs one id lookup');

reset_world();
$first = stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E, read_at => $E + 4);
$second = stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E + 3, read_at => $E + 4);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E), $first,
    'in-order markers: the first claims the first kill');
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E + 3), $second,
    'and the second claims the second');
is(scalar(@selects), 0, 'in-order markers need no id lookup');

reset_world();
stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E, read_at => $E + 3);
stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E + 2, read_at => $E + 3);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E + 1), undef,
    'two kills equally near the epoch claim nothing rather than guess');
is($fc_match_description, 'unambiguous logged-second', 'and the rejection says why');

reset_world();
stock_kill(killer => 1, victim => 2, weapon => 'kar', logged_at => $E, read_at => $E + 4, server => 8);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E), undef,
    'a kill on another server is never a candidate');

reset_world();
my $unknown = stock_kill(killer => 1, victim => 2, weapon => 'garand', logged_at => $E, read_at => $E + 4);
is(marker(killer => 1, victim => 2, weapon => 'mortar', epoch => $E), $unknown,
    'the unresolved-weapon label still accepts any weapon');

# Rows queued before a daemon restart are not in the index; the producer window
# still serves them, so nothing that matched before stops matching.
reset_world();
push(@table, { id => 50, serverId => 7, killerId => 1, victimId => 2, weapon => 'kar',
    eventTime => $E + 1, claimed => 0 });
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E), 50,
    'an unindexed on-time row falls back to the producer window');

# --- a kill outside a match carries the same clock and used to lose it -------
# ksc_emit_frag_context stamps event_epoch before it looks the match up, so an
# untracked kill has the producer second too. Joining on when the marker was
# read instead makes correlation depend on the producer's buffer flush.
reset_world();
my $untracked = stock_kill(killer => 1, victim => 2, weapon => 'kar',
    logged_at => $E, read_at => $E + 4);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E,
        read_at => $E + 20, context_error => 'legacy producer context absent'),
    $untracked,
    'an untracked kill correlates on the producer second -- the receipt window has moved past it');

# Same pair and weapon twice inside the receipt window with the first marker
# lost: FIFO over that window hands the second marker the first kill's row,
# which is a wrong attachment rather than a miss.
reset_world();
my $early = stock_kill(killer => 1, victim => 2, weapon => 'kar',
    logged_at => $E, read_at => $E + 1);
my $later = stock_kill(killer => 1, victim => 2, weapon => 'kar',
    logged_at => $E + 5, read_at => $E + 6);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E + 5,
        read_at => $E + 8, context_error => 'legacy producer context absent'),
    $later,
    'an untracked repeat kill claims its own row, not the earlier unclaimed one');
ok(!(grep { $_->{id} == $early && $_->{claimed} } @table),
    'and the earlier kill keeps its context slot');

# Nothing bounds an untracked epoch, so a producer clock that disagrees with
# ours keeps today's window rather than joining on a nonsense second.
reset_world();
my $skewed = stock_kill(killer => 1, victim => 2, weapon => 'kar',
    logged_at => $E + 4995, read_at => $E + 4995);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E,
        read_at => $E + 5000, context_error => 'legacy producer context absent'),
    $skewed,
    'a skewed producer epoch falls back to the receipt window');
is($fc_match_description, 'legacy receipt window', 'and the window is named');

reset_world();
my $no_epoch = stock_kill(killer => 1, victim => 2, weapon => 'kar',
    logged_at => $E, read_at => $E + 2);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => undef,
        read_at => $E + 3, context_error => 'legacy producer context absent'),
    $no_epoch,
    'an emitter that sends no epoch at all still uses the receipt window');

reset_world();
my $tracked = stock_kill(killer => 1, victim => 2, weapon => 'kar',
    logged_at => $E, read_at => $E + 1);
is(marker(killer => 1, victim => 2, weapon => 'kar', epoch => $E), $tracked,
    'a tracked kill still matches');
is($fc_match_description, 'logged-second',
    'and is still reported against the logged second');

reset_world();
main::ktpNoteRecordedFrag(7, 1, 2, 'kar', $E, $E);
main::ktpNoteRecordedFrag(7, 3, 4, 'kar', $E + 120, $E + 120);
ok(!exists($g_ktpRecentFrags{7}{'1 2'}), 'the index forgets kills older than a minute');
ok(exists($g_ktpRecentFrags{7}{'3 4'}), 'and keeps the one just noted');

like($frag_branch, qr/\$fc_seen->\{claimed\} = 1\s*\n\s*if \(defined\(\$fc_rv\) && \$fc_rv > 0 && ref\(\$fc_seen\)\)/,
    'an index entry is marked claimed only when the UPDATE took a row');
my $handlers = slurp($SCRIPT_DIR . 'HLstats_EventHandlers.plib');
like($handlers, qr/&recordEvent\(\s*"Frags".*?\);\s*&ktpNoteRecordedFrag\(\$g_servers\{\$s_addr\}->\{'id'\}, \$killer->\{playerid\},\s*\$victim->\{playerid\}, \$weapon, \$ev_remotetime, \$ev_unixtime\);/s,
    'every recorded frag is indexed with its logged second and its row second');

# --- migration 020 -----------------------------------------------------------
my $migration20 = slurp($MIGRATION20);
like($migration20, qr/COLUMN_NAME = 'frag_context_certified'/,
    'migration 020 guards the additive column');
like($migration20, qr/ADD COLUMN frag_context_certified TINYINT\(1\) NOT NULL DEFAULT 0/,
    'existing rows default to uncertified');
unlike($migration20, qr/^\s*UPDATE\s+hlstats_Events_Frags/mi,
    'migration 020 runs no backfill -- certification cannot be re-derived from content');
like($migration20, qr/must run before daemon/i,
    'migration 020 states its ordering against the daemon');

# 019 reads "flag set, all context at default" as proof the flag is false. Once
# 020 exists the daemon writes exactly that shape for an unusable payload, and a
# certified kill can legitimately measure every default at once, so re-running
# it would withdraw live claims.
my $migration19 = slurp($MIGRATION19);
like($migration19, qr/COLUMN_NAME = 'frag_context_certified'/,
    'migration 019 is guarded on whether 020 has been applied');
like($migration19, qr/IF\(\@certified_exists > 0, 'DO 0'/,
    'migration 019 degrades to a no-op once certification exists');

done_testing();
