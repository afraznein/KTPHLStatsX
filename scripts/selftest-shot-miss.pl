#!/usr/bin/perl
#
# The shot_miss stream has to be named in the same nine hand-maintained places
# in hlstats.pl that selftest-move-census.pl and selftest-aim-vis.pl enumerate
# for their streams. Those files exist because `shot` was added to four of them
# and missed in the capture-health allow-list, which would have left the
# highest-volume stream with no drop detection and nothing would have failed.
#
# It also pins the contracts this stream cannot be allowed to lose, each of
# which is silent when broken and has a tempting wrong form:
#   - the RAY's presence key is trace_frac, because a world coordinate has no
#     out-of-range value to test instead;
#   - the trace COUNT has its OWN presence key, because it is a separate stash
#     on the same cmd and survives when the ray does not;
#   - an absent ray lands NULL, never 0 0 0, which is a legal world coordinate;
#   - trace_ent and trace_weapon_id keep -1 as DATA once a ray exists.
#
# Registration is asserted on the shipped hlstats.pl text; the row discipline is
# asserted by running the shipped handler, the way selftest-shot-hitgroup-rewind
# does. A stream can be wired correctly and still be wrong, but it cannot be
# wired incorrectly and be right.
#
# Exact-text checks use index() with single-quoted needles on purpose: the
# strings being matched are full of $sigils, and a qr// would interpolate them
# into nothing and then pass against anything.

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $DIR = dirname($0);
my $SRC = "$DIR/hlstats.pl";
open(my $fh, '<', $SRC) or die "cannot read $SRC: $!";
my $source = do { local $/; <$fh> };
close($fh);
$source =~ s/\r//g;

sub body_of {
    my ($name) = @_;
    my ($body) = ($source =~ /sub \Q$name\E\s*\{(.*?)\n\}/s);
    return undef if (!defined($body));
    return $body;
}

sub has {
    my ($haystack, $needle, $name) = @_;
    ok(defined($haystack) && index($haystack, $needle) >= 0, $name)
        or diag("missing literal: $needle");
}

sub hasnt {
    my ($haystack, $needle, $name) = @_;
    ok(!defined($haystack) || index($haystack, $needle) < 0, $name)
        or diag("unexpected literal: $needle");
}

# --- 0. the needles themselves are real ------------------------------------
# A literal-substring test passes vacuously if the needle is misspelled in a way
# that never appears. Anchor on something that must be there and on something
# that must not, so the harness is shown to discriminate.
has($source, 'sub doEvent_KTPShotMiss', 'control: a known-present literal is found');
hasnt($source, 'sub doEvent_KTPZzzNoSuchHandler', 'control: an absent literal is not found');

# --- 1. the nine registration points ---------------------------------------

# Asserted as MEMBERSHIP in each alternation, never as a remembered tail of one.
# Pinning the tail is what broke all three sibling move-census assertions the
# moment aim_vis was added: a brittle needle on a shared list reports one stream
# as unregistered because a different one arrived.
sub registered_in {
    my ($lists, $member, $name) = @_;
    cmp_ok(scalar(@$lists), '>', 0, "$name (a list of that shape was found at all)")
        or return;
    my %m = map { $_ => 1 } map { split(/\|/, $_) } @$lists;
    ok($m{$member}, $name) or diag("lists were: " . join(' // ', @$lists));
    ok(!$m{'zzznope'}, "$name -- control: a name in no list is not matched");
}

{
    my @obs = ($source =~
        /\$ev_obj_a =~ \/\^\(([^)]*)\)\$\/\)\s*\{\s*\n\s*my %sequence_type/g);
    registered_in(\@obs, 'shot_miss',
        'shot_miss is in the capture-marker observation whitelist');
}

# The wire name and the internal stream name are the SAME string here. move_census
# -> "move" is the only place in this codebase where they differ, and five
# separate sites index on the internal one, so a mismatch here goes dark in all
# five at once.
#
# Scoped to the %sequence_type hash, NOT grepped whole-file: the identical pair
# also appears in the resend %by_trigger below, so a whole-file needle passes on
# the strength of the other site even with this one deleted. Mutation found that.
{
    # FOUR %sequence_type hashes exist in this file and the needle
    # `shot_miss => "shot_miss"` also appears in the resend %by_trigger below, so
    # a whole-file match passes with this one deleted on the strength of another
    # site -- mutation found exactly that. Scope to the hash the OBSERVE call
    # reads, by matching the call itself.
    my @maps = ($source =~
        /my %sequence_type = \(([^;]*?)\);\s*\n\s*ktpObserveCaptureMarker\(\$sequence_type/gs);
    cmp_ok(scalar(@maps), '>', 0, 'an observation %sequence_type map was found');
    my @capture = grep { index($_, 'life_boundary => "life"') >= 0 } @maps;
    is(scalar(@capture), 1,
        'exactly one observation map carries the buffered capture-marker names');
    has($capture[0], 'shot_miss => "shot_miss"',
        'shot_miss maps to the "shot_miss" sequence type');
    hasnt($capture[0], 'zzznope', 'control: a name in no map is not matched');
}

# DELIBERATELY NOT a tenth site, and it reads exactly like a missed one: the
# identity-unresolved rejection path keeps its OWN, shorter whitelist, and
# `shot`, `move_census` and `aim_vis` are all absent from it already. Those
# streams get no reject row when the buffered identity cannot be resolved, so
# adding shot_miss there would change this stream's behaviour relative to every
# sibling it was modelled on. Pinned so the next reader does not "fix" it.
{
    my @reject = ($source =~
        /my %sequence_type = \(([^;]*?)\);\s*\n\s*if \(\$ev_obj_a eq "life_boundary"/gs);
    is(scalar(@reject), 1, 'the identity-unresolved rejection map was found');
    hasnt($reject[0], 'shot_miss',
        'shot_miss is absent from the identity-unresolved rejection map, like its siblings');
    hasnt($reject[0], 'shot => "shot"',
        'control: `shot` is absent from it too, which is why shot_miss is');
    has($reject[0], 'life_boundary => "life"',
        'control: the map really is the one that handles life_boundary');
}

{
    my @buf = ($source =~ /\$ev_obj_a =~ \/\^\(\?:([^)]*)\)\$\//g);
    registered_in(\@buf, 'shot_miss',
        'shot_miss is in the buffered-identity whitelist');
}

# Missing from the buffered-identity list above and this branch never fires at
# all -- no row, and no reject row either, because the elsif guard is the
# resolved player id.
like($source, qr/\}\s*elsif\s*\(\$ev_obj_a\s+eq\s+"shot_miss"\)\s*\{/,
    'shot_miss has a dispatch branch');

has($source, 'shot_miss => $capabilities{shot_miss} ? 1 : 0',
    'the accepted-manifest record carries the shot_miss capability bit');

{
    # Fail-closed: a type not named here returns 0 unconditionally, so the
    # dispatch branch would always take the reject path.
    my $auth = body_of('ktpCaptureManifestAuthorizes');
    my ($types) = (($auth // '') =~ /\$event_type !~ \/\^\(\?:([^)]*)\)\$\//);
    registered_in([defined($types) ? $types : ()], 'shot_miss',
        'ktpCaptureManifestAuthorizes accepts "shot_miss" as an event type');
}

# Deliberately NOT an assertion that a new schema ordinal was accepted. This
# stream takes none: the capability bit is the gate, exactly as for move and
# aim_vis. Pin the whitelist to the ruled set, so anything widening it has to
# name the ruled change that owns the ordinal -- and this stream is not it.
{
    my $validator = body_of('ktpValidateCaptureManifestPayload');
    my ($clause) = (($validator // '') =~ /return "unsupported schema"(.*?);/s);
    my @ordinals = sort { $a <=> $b } (($clause // '') =~ /!= (\d+)/g);
    is(join(',', @ordinals), '21,22,23,24,25,26',
        'no schema ordinal was claimed for this stream; the capability bit gates it');
}

# And NOT in @required_capabilities: a producer lacking the bit would then have
# its whole manifest refused, taking every other stream for that half with it.
{
    my $validator = body_of('ktpValidateCaptureManifestPayload') // '';
    my ($required) = ($validator =~ /my \@required_capabilities = (.*?);\n/s);
    ok(defined($required), 'the required-capability lists were found');
    unlike($required // 'shot_miss', qr/\bshot_miss\b/,
        'shot_miss is NOT required of a manifest -- requiring it refuses the whole manifest');
    like($required // '', qr/\bframe?g_context\b|\bfrag_context\b/,
        'control: the required lists really are the ones that name frag_context');
}

{
    # return 1 means DROP, so an unmapped trigger makes gap repair request
    # resends and then throw every one of them away.
    my $resend = body_of('ktpResentLineIsRedundant');
    has($resend, 'shot_miss => "shot_miss"',
        'resent shot_miss lines are recognised (or every resend of one is dropped)');
}

{
    # The one that was missed for `shot`. ksc_emit_health loops the producer's
    # whole event enum, so a plugin that GAINS a stream emits a health row for it
    # whether or not it advertises the capability -- and an unknown type fails
    # capture_health for the whole half, for every stream.
    my ($allowed) = ($source =~ /my %allowed = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    ok(defined($allowed), 'the capture-health allow-list was found');
    like($allowed // '', qr/\bshot_miss\b/,
        'the capture-health allow-list names "shot_miss" -- the exact line `shot` was missed on');
    unlike($allowed // 'zzznope', qr/\bzzznope\b/,
        'control: a name in no allow-list is not matched');
}

{
    # The same class of miss four lines further down, which the allow-list
    # assertion does not catch: a stream in neither %always_active nor
    # %manifest_gated falls through the elsif and returns "" unconditionally, so
    # it can go completely dark and nothing ever warns.
    my ($gated) = ($source =~ /my %manifest_gated = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    ok(defined($gated), 'the manifest-gated silent-stream set was found');
    like($gated // '', qr/\bshot_miss\b/,
        'shot_miss is in %manifest_gated, so a dark stream is reported');
    my ($always) = ($source =~ /my %always_active = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    unlike($always // '', qr/\bshot_miss\b/,
        'and NOT in %always_active -- a capability-gated stream is legitimately absent');
}

# --- 2. the batch is drained everywhere its sibling is ---------------------
# A queue below the size threshold with no half boundary sits indefinitely, so
# the boundary and shutdown drains are the only things that bound its latency.
{
    my $flush_all = body_of('flushAll');
    has($flush_all, 'flushShotMissEvents();',
        'the shutdown drain empties the shot_miss queue');
    has($source, "\t\t\tflushShotMissEvents();",
        'the half-boundary health drain empties it too');
    my $handler = body_of('doEvent_KTPShotMiss');
    has($handler, '>= $g_ktp_shot_miss_queue_size',
        'and the handler flushes on its own size threshold');
}

# Must be declared above the daemon main loop, which never exits -- file-scope
# code after it never runs. selftest-no-code-after-main-loop.pl enforces the
# rule; this pins that THIS queue obeys it.
{
    my $loop_at = index($source, 'Must stay above the main loop');
    cmp_ok($loop_at, '>', 0, 'control: the main-loop marker comment was found');
    cmp_ok(index($source, '@g_ktpShotMissQueue = ();'), '<', $loop_at,
        'the shot_miss queue is declared above the main loop');
}

# --- 3. the row discipline, by running the shipped handler ------------------
our (%g_servers, $s_addr, @sql, %g_ktpAcceptedCaptureManifests, %g_ktpMatchContext,
    @g_ktpShotMissQueue, $g_ktp_shot_miss_queue_size);
$s_addr = "10.0.0.1:27015";
$g_servers{$s_addr} = { id => 9 };
$g_ktp_shot_miss_queue_size = 1000;
sub execNonQuery { push(@sql, $_[0]); return 1; }
sub quoteSQL { my ($v) = @_; $v =~ s/'/''/g; return $v; }
sub printEvent { }
sub ktpHasExplicitProducerContext { return 1; }
sub ktpResolveValidatedProducerEventContext { return ($_[1], "dod_anzio", "", "producer"); }
sub ktpWarnProducerClock { }
{
    no strict 'vars';
    no warnings 'redefine';
    my $code = "";
    for my $sub (qw(ktpCaptureContextKey doEvent_KTPShotMiss flushShotMissEvents)) {
        my $body = body_of($sub);
        die "could not extract sub $sub from hlstats.pl" if (!defined($body));
        $code .= "sub $sub {" . $body . "\n}\n";
    }
    eval $code . "1;" or die "handler eval failed: $@";
}

$g_ktpAcceptedCaptureManifests{join("\x1e", $s_addr, 'KTP-1', 1)} =
    { schema => 23, shot_miss => 1 };

my %RAY = (weapon_id => 10, matchid => 'KTP-1', half => 1, game_time => '245.32',
    event_epoch => 1790000001, sequence => 7, shot_sequence => 41,
    cmd_traces_any => 3, trace_frac => 5000, trace_flags => 4, trace_ent => 0,
    trace_weapon_id => 10, ray_start => '10 20 30', ray_aim => '4000 20 30',
    ray_end => '2005 20 30');

sub split_values {
    my ($text) = @_;
    my (@out, $cur, $q) = ();
    $cur = "";
    for my $ch (split //, $text) {
        if ($ch eq "'") { $q = !$q; $cur .= $ch; next; }
        if ($ch eq ',' && !$q) { push(@out, $cur); $cur = ""; next; }
        $cur .= $ch;
    }
    push(@out, $cur);
    return map { s/^\s+|\s+$//gr } @out;
}

sub miss_row {
    my (%p) = @_;
    @sql = ();
    @g_ktpShotMissQueue = ();
    my $status = doEvent_KTPShotMiss(4242, \%p);
    flushShotMissEvents();
    return (undef, $status) if (@sql != 1);
    my ($cols, $vals) = ($sql[0] =~ /INSERT INTO ktp_shot_miss_events\s*\((.*?)\)\s*VALUES\s*\((.*)\)\s*ON DUPLICATE/s)
        or return (undef, "unparsed SQL");
    my @c = map { s/^\s+|\s+$//gr } split(/,/, $cols);
    my @v = split_values($vals);
    # The guard that catches a column added to the INSERT list but not to the
    # value string, which otherwise fails only against a live MySQL.
    return (undef, "column/value count " . scalar(@c) . "/" . scalar(@v)) if (@c != @v);
    my %row;
    @row{@c} = @v;
    return (\%row, $status);
}

my ($row, $status);

($row, $status) = miss_row(%RAY);
ok($row, 'a ray produces one parseable INSERT, columns == values') or diag($status);
is($row->{trace_frac}, 5000, 'control: the fraction is read from the marker');
is($row->{shot_sequence}, 41, 'the join key back to the shot row is stored');
is(join(',', map { $row->{$_} } qw(ray_start_x ray_start_y ray_start_z)), '10,20,30',
    'the ray start is stored as three integer world units');
is(join(',', map { $row->{$_} } qw(ray_end_x ray_end_y ray_end_z)), '2005,20,30',
    'and so is where it stopped');
is($row->{trace_ent}, 0, 'worldspawn (entity 0) is a real value, kept');
is($row->{cmd_traces_any}, 3, 'the trace count is stored');

# trace_frac is the presence key, and the whole ray group rides it.
($row) = miss_row(%RAY, trace_frac => -1);
is($row->{trace_frac}, 'NULL', 'trace_frac -1 is the no-sample marker, stored NULL');
is($row->{ray_start_x}, 'NULL', 'and it voids the coordinates rather than storing them');
is($row->{trace_flags}, 'NULL', 'and the flags with them');
is($row->{cmd_traces_any}, 3,
    'but NOT the trace count -- a separate stash with its own presence key');

($row) = miss_row(%RAY, trace_frac => 10001);
is($row->{trace_frac}, 'NULL', 'a fraction above 10000 is not a fraction; voids the group');

# An absent ray must never land as the origin.
($row) = miss_row(%RAY, trace_frac => -1, ray_start => '', ray_aim => '', ray_end => '');
is(join(',', map { $row->{$_} } qw(ray_start_x ray_aim_y ray_end_z)), 'NULL,NULL,NULL',
    'an empty coordinate field lands NULL -- 0 0 0 is a legal world coordinate');

# -1 is DATA on these two once a ray exists, and the array's pre-read fill when
# it does not. The presence key is what tells the two apart.
($row) = miss_row(%RAY, trace_ent => -1, trace_weapon_id => -1);
is($row->{trace_ent}, -1, 'trace_ent -1 (no edict at all) is real data under a ray');
is($row->{trace_weapon_id}, -1, 'and so is an unstamped trace weapon');

# 0 is a real flags value: open space, stopped short, hit no player.
($row) = miss_row(%RAY, trace_flags => 0);
is($row->{trace_flags}, 0, 'trace_flags 0 is a measurement, not an absence');
($row) = miss_row(%RAY, trace_flags => 16);
is($row->{trace_flags}, 'NULL', 'a value outside the 4-bit field voids it');

# Bit3 says the cmd's first trace hit a player, so it was not a miss. Stored
# rather than filtered: the native declines to make that call, and a
# producer-side filter would make this table's population a producer guess.
($row) = miss_row(%RAY, trace_flags => 8);
is($row->{trace_flags}, 8, 'a bit3 row is stored, not suppressed -- filter it at read time');

# A count with no ray is still a measurement of a miss.
($row, $status) = miss_row(%RAY, trace_frac => -1, cmd_traces_any => 1);
ok($row, 'a trace count with no ray still produces a row') or diag($status);
is($row->{cmd_traces_any}, 1, 'and carries the count');

# Neither half is a parse failure, not a quiet empty row.
($row, $status) = miss_row(%RAY, trace_frac => -1, cmd_traces_any => -1);
ok(!$row, 'neither a ray nor a count is refused rather than stored empty');
like($status // '', qr/dropped/, 'and the refusal says so, so the marker is rejected');

# Same sequence rule as the shot row: NULL, never 0, or the dedup UNIQUE plus
# ON DUPLICATE KEY UPDATE collapses every such row in the half onto one.
($row) = miss_row(%RAY, sequence => undef);
is($row->{producer_sequence}, 'NULL', 'a missing sequence is NULL, never 0');
($row) = miss_row(%RAY, sequence => 'x7');
is($row->{producer_sequence}, 'NULL', 'and so is a non-numeric one');
($row) = miss_row(%RAY, shot_sequence => undef);
is($row->{shot_sequence}, 'NULL',
    'an unjoinable row keeps its measurement but does not claim to point at shot 0');

# The manifest bit is the gate.
{
    %g_ktpAcceptedCaptureManifests = ();
    my ($r, $st) = miss_row(%RAY);
    ok(!$r, 'no accepted manifest means no row');
    like($st // '', qr/shot_miss capability/, 'and the reason names the capability');
    $g_ktpAcceptedCaptureManifests{join("\x1e", $s_addr, 'KTP-1', 1)} =
        { schema => 23, shot_miss => 0 };
    ($r, $st) = miss_row(%RAY);
    ok(!$r, 'a manifest without the bit means no row either');
    $g_ktpAcceptedCaptureManifests{join("\x1e", $s_addr, 'KTP-1', 1)} =
        { schema => 22, shot_miss => 1 };
    ($r, $st) = miss_row(%RAY);
    ok(!$r, 'and schema 22 is below the authorizer floor');
    $g_ktpAcceptedCaptureManifests{join("\x1e", $s_addr, 'KTP-1', 1)} =
        { schema => 23, shot_miss => 1 };
    ($r, $st) = miss_row(%RAY);
    ok($r, 'control: the bit restored, the row lands again') or diag($st);
}

# A batched INSERT must not be INSERT IGNORE: that downgrades truncation,
# out-of-range and bad-datetime errors to warnings, not just a duplicate key.
{
    my $flush = body_of('flushShotMissEvents');
    has($flush, 'ON DUPLICATE KEY UPDATE id=id',
        'the batch converts only the duplicate key a retried batch produces');
    # Comments stripped first: the rule is NAMED in the comment right beside the
    # statement, so the un-stripped needle matches the prose and the assertion
    # passes whatever the code does.
    my $code = join("\n", grep { !/^\s*#/ } split(/\n/, $flush // ''));
    hasnt($code, 'INSERT IGNORE',
        'and the statement itself does not silence every other error with IGNORE');
    has($code, 'INSERT INTO ktp_shot_miss_events',
        'control: the statement really was found after stripping comments');
    has($flush, 'row(s) lost', 'a failed batch reports its blast radius');
}

# --- 4. the migration ------------------------------------------------------
{
    my $path = "$DIR/../sql/migrate_052_shot_miss_events.sql";
    open(my $mh, '<', $path) or die "cannot read $path: $!";
    my $sql = do { local $/; <$mh> };
    close($mh);
    $sql =~ s/\r//g;
    like((split(/\n/, $sql))[0], qr/^-- ENGINE: mysql /,
        'line 1 declares the engine, so the operator queue cannot mistake it for Postgres');
    like($sql, qr/CREATE TABLE IF NOT EXISTS ktp_shot_miss_events/,
        'the table is created idempotently');
    like($sql, qr/UNIQUE KEY \w+ \(server_id, match_id, half, producer_sequence\)/,
        'the dedup contract is in the CREATE TABLE, not deferred to a later migration');
    for my $col (qw(shot_sequence cmd_traces_any trace_frac trace_flags trace_ent
                    trace_weapon_id ray_start_x ray_start_y ray_start_z
                    ray_aim_x ray_aim_y ray_aim_z ray_end_x ray_end_y ray_end_z)) {
        like($sql, qr/^\s*\Q$col\E\s+\w/m, "the table declares $col");
    }
    like($sql, qr/trace_ent\s+MEDIUMINT(?!\s+UNSIGNED)/,
        'trace_ent is SIGNED -- -1 is real data on it');
    like($sql, qr/trace_weapon_id\s+SMALLINT(?!\s+UNSIGNED)/,
        'and so is trace_weapon_id');
    # Comments stripped: this migration EXPLAINS the grant obligation at
    # length, so an un-stripped needle matches that prose rather than a
    # statement, and would pass even if a real GRANT were executed.
    my $ddl = join("\n", grep { !/^\s*--/ } split(/\n/, $sql));
    unlike($ddl, qr/\bGRANT\b/,
        'no GRANT is executed here -- a missing account is ERROR 1410; it is staged for the operator');
    like($ddl, qr/\bCREATE TABLE\b/,
        'control: the DDL really was found after stripping comments');
    like($sql, qr/\bGRANT SELECT\b/,
        'but the obligation IS written down, or the table reads as absent rather than denied');

    # Every column the daemon names in its INSERT has to exist in the table, or
    # the daemon loses EVERY row of the stream rather than one field of it.
    my $flush = body_of('flushShotMissEvents') // '';
    my ($cols) = ($flush =~ /INSERT INTO ktp_shot_miss_events\s*\((.*?)\)/s);
    ok(defined($cols), 'the INSERT column list was found');
    my @named = grep { length } map { s/^\s+|\s+$//gr } split(/,/, $cols // '');
    cmp_ok(scalar(@named), '>', 10, 'control: the column list really was parsed');
    for my $col (@named) {
        like($sql, qr/^\s*\Q$col\E\s+\w/m, "migration declares the INSERTed column $col");
    }
}

done_testing();
