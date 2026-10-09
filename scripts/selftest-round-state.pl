#!/usr/bin/perl
# Round-freeze state and what it may and may not un-tag.
#
# KTP_ROUND_FREEZE / KTP_ROUND_LIVE flip a receipt-time round_live flag that
# recordEvent() uses to leave freeze-time kills without a match_id. That is
# intended for frags. It is wrong for two streams that carry their own producer
# context: the flag-ownership timeline (the flags reset to their default owners
# during the freeze, and the round-winning capture's row often lands after the
# freeze marker) and the per-hit damage ledger (stats_logging buffers damage for
# up to KSC_BUF_FLUSH_SECS, the freeze marker is written at once). A proven
# producer tuple has to decide those rows' match, whatever round_live says.
#
# The bare-marker dispatch chain, the damage branch of the triggered-line
# dispatch and every handler they reach are lifted out of hlstats.pl and run;
# only the database is replaced, by an in-memory ktp_matches that the shipped
# KTP_MATCH_START / KTP_HALF_END handlers themselves write.
#
#   perl scripts/selftest-round-state.pl        # exit 0 = pass
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $DIR = dirname($0);
sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close($fh);
    $text =~ s/\r//g;
    return $text;
}
my $source = slurp("$DIR/hlstats.pl");

sub body_of {
    my ($name) = @_;
    my ($body) = ($source =~ /\nsub \Q$name\E\s*\{(.*?)\n\}/s);
    die "could not extract sub $name from hlstats.pl" if (!defined($body));
    return "sub $name {$body\n}\n";
}

sub slice {
    my ($begin, $end) = @_;
    my $from = index($source, $begin);
    die "missing source anchor: $begin" if ($from < 0);
    my $to = index($source, $end, $from + length($begin));
    die "missing source anchor: $end" if ($to < 0);
    return substr($source, $from, $to - $from);
}

# The bare KTP_* marker chain from KTP_MATCH_START through KTP_FLAG_STATE. Each
# branch opens with "} elsif", so the slice runs behind an always-false if.
my $marker_chain = slice('} elsif ($s_output =~ /^KTP_MATCH_START',
    '} elsif ($s_output =~ /^KTP_SCORE_EVENT');
like($marker_chain, qr/KTP_ROUND_FREEZE.*KTP_ROUND_LIVE.*KTP_FLAG_STATE/s,
    "control: the lifted chain carries the freeze, live and flag-state branches");

# The damage branch of the player-player "triggered" dispatch.
my $damage_branch = slice('} elsif ($ev_obj_a eq "damage") {',
    "\n\t\t\t\t} else {\n");
like($damage_branch, qr/doEvent_KTPDamage\(/, "control: the lifted damage branch calls the handler");

# The daemon's own player-player line pattern, so a fixture that stops matching
# the shipped shape fails here instead of being parsed by a private copy.
my $triggered_re;
{
    my $at = index($source, '\s(triggered(?:\sa)?)\s');
    die "missing triggered-line pattern" if ($at < 0);
    my $open = rindex($source, '$s_output =~ /', $at);
    my $close = index($source, '/x)', $at);
    my $pattern = substr($source, $open + length('$s_output =~ /'),
        $close - $open - length('$s_output =~ /'));
    $triggered_re = qr/$pattern/x;
}

# --- collaborators --------------------------------------------------------------
our (%g_servers, %g_ktpMatchContext, %g_ktpProducerContextCache,
     %g_ktpCaptureSequences, %g_ktpCaptureClockWarnings, %g_eventtable_data,
     $g_event_queue_size, $s_addr, $s_output, $ev_properties, %ev_properties,
     %ev_properties_hash, $ev_type, $ev_status, $ev_obj_c,
     $ktp_actor_player_id, $ktp_victim_player_id, $i, $j,
     @sql, @logged, %ktp_matches, $now);
$s_addr = '127.0.0.1:27015';
{
    package StubServer;
    sub get_map { return $_[0]->{map}; }
}
%g_servers = ($s_addr => bless({ id => 42, map => 'dod_anzio' }, 'StubServer'));
$g_event_queue_size = 1_000_000;
$g_eventtable_data{Frags} = { nullallowed => 0, queue => [] };
our $ev_unixtime = 0;

sub quoteSQL { my ($v) = @_; $v =~ s/\\/\\\\/g; $v =~ s/'/\\'/g; return $v; }
sub printEvent { push(@logged, join(' ', map { $_ // '' } @_[0, 1])); return 1; }
sub ktpObserveCaptureMarker { return; }
sub flushEventTable { return; }

# A collaborator here, not the subject -- but lifted rather than stubbed, so a
# map name this test feeds in is judged exactly as the daemon judges it.
{
    my $plib = slurp("$DIR/HLstats.plib");
    my ($body) = ($plib =~ /\nsub ktpValidMapName\s*\{(.*?)\n\}/s);
    die "could not extract sub ktpValidMapName from HLstats.plib" if (!defined($body));
    eval "sub ktpValidMapName {$body\n}\n1;"
        or die "cannot load shipped ktpValidMapName: $@";
}

# ktp_matches in memory: the shipped MATCH_START INSERT and HALF_END UPDATE are
# what open and close each interval.
sub execNonQuery {
    my ($q) = @_;
    push(@sql, $q);
    if ($q =~ /INSERT INTO ktp_matches .*?VALUES \('([^']*)', (\d+), '([^']*)', (\d+),/s) {
        my ($mid, $sid, $map, $half) = ($1, $2, $3, $4);
        $ktp_matches{$mid}{$half} ||= { match_id => $mid, half => $half,
            map_name => $map, start_epoch => $now, end_epoch => undef };
    } elsif ($q =~ /UPDATE ktp_matches\s+SET end_time = NOW\(\)\s+WHERE match_id = '([^']*)'.*?AND half = (\d+)/s) {
        my $row = $ktp_matches{$1}{$2};
        $row->{end_epoch} = $now if ($row && !defined($row->{end_epoch}));
    }
    return 1;
}
{
    package StubResult;
    sub fetchrow_hashref { my ($self) = @_; return shift(@{$self->{rows}}); }
    sub finish { return 1; }
}
sub doQuery {
    my ($q) = @_;
    my ($mid) = ($q =~ /match_id = '([^']*)'/);
    my ($epoch) = ($q =~ /start_time <= FROM_UNIXTIME\((\d+)\)/);
    my @rows;
    if (defined($mid) && defined($epoch)) {
        for my $half (sort { $a <=> $b } keys %{$ktp_matches{$mid} || {}}) {
            my $r = $ktp_matches{$mid}{$half};
            next if ($r->{start_epoch} > $epoch);
            next if (defined($r->{end_epoch}) && $r->{end_epoch} < $epoch);
            push(@rows, { %{$r}, proof_epoch => $now });
        }
    }
    return bless({ rows => \@rows }, 'StubResult');
}

{
    no strict 'vars';
    no warnings 'redefine';
    my $code = join('', map { body_of($_) } qw(
        getProperties parseHalfNumber recordEvent
        doEvent_KTPMatchStart doEvent_KTPHalfEnd
        doEvent_KTPDamage doEvent_KTPFlagState
        ktpIntOrNull ktpNumOrNull
        ktpValidateProducerEventClock ktpResolveProducerEventContext
        ktpResolveValidatedProducerEventContext ktpHasExplicitProducerContext
        ktpWarnProducerClock ktpRejectCaptureMarker));
    eval "$code\n1;" or die "cannot load shipped handlers: $@";
}

# --- drivers --------------------------------------------------------------------
sub marker_line {
    my ($line) = @_;
    $s_output = $line;
    ($ev_properties, $ev_type, $ev_status) = (undef, undef, undef);
    %ev_properties = ();
    @sql = ();
    no strict 'vars';
    eval "if (0) {\n$marker_chain}\n1;" or die "cannot run shipped marker chain: $@";
    return $ev_status;
}

sub damage_line {
    my ($line) = @_;
    my @m = ($line =~ $triggered_re);
    die "damage fixture did not match the shipped pattern: $line" unless (@m && $m[1] eq 'triggered');
    my ($player, $verb, $obj_a, $obj_b, $obj_c, $props) = @m;
    die "fixture is not a damage line" unless ($obj_a eq 'damage');
    %ev_properties_hash = getProperties($props);
    ($ev_obj_c, $ev_type, $ev_status) = ($obj_c, undef, undef);
    ($ktp_actor_player_id, $ktp_victim_player_id) = (9001, 9002);
    @sql = ();
    my $ev_obj_a = $obj_a;
    no strict 'vars';
    eval "if (0) {\n$damage_branch}\n1;" or die "cannot run shipped damage branch: $@";
    my @rows = grep { /INSERT INTO ktp_damage_events/ } @sql;
    return (undef, $ev_status) if (@rows != 1);
    my ($match, $half) = ($rows[0] =~ /VALUES\s*\(\s*\d+,\s*(NULL|'[^']*'),\s*(\d+),/s);
    return ({ match_id => $match, half => $half }, $ev_status);
}

sub flag_row {
    my @rows = grep { /INSERT IGNORE INTO ktp_flag_state_events/ } @sql;
    return undef if (@rows != 1);
    my ($match, $half, $map, $idx, $owner) = ($rows[0] =~
        /VALUES\s*\(\s*\d+,\s*'([^']*)',\s*(\d+),\s*'([^']*)',\s*(\d+),\s*(?:NULL|'[^']*'),\s*(\d+),/s);
    return { match_id => $match, half => $half, map => $map, flag_index => $idx, owner => $owner };
}

sub frag_match_id {
    $g_eventtable_data{Frags}{queue} = [];
    recordEvent("Frags", 0, 1, 2);
    my ($value) = @{$g_eventtable_data{Frags}{queue}};
    my ($match) = ($value =~ /^\(FROM_UNIXTIME\(\d+\),\d+,'[^']*',(NULL|'[^']*')/);
    return $match;
}

my $MID = 'KTP-7-1790000000';
sub flag_state {
    my (%o) = @_;
    my %f = (map => 'dod_anzio', flag_index => 2, flag_name => 'church', owner => 1,
        initial => 0, game_time => '401.50', round_time_left => '120.0',
        matchid => $MID, half => 1, sequence => 30, event_epoch => $now - 5, %o);
    my $tail = join(' ', map { defined($f{$_}) ? "($_ \"$f{$_}\")" : () }
        qw(map flag_index flag_name owner initial game_time round_time_left matchid half sequence event_epoch));
    return marker_line("KTP_FLAG_STATE $tail");
}
sub damage {
    my (%o) = @_;
    my %f = (damage => 40, damage_capped => 40, hitplace => 2, health_before => 100,
        health_after => 60, damage_applied => 40, matchid => $MID, half => 1,
        game_time => '400.25', event_epoch => $now - 3, sequence => 31, %o);
    my $tail = join(' ', map { "($_ \"$f{$_}\")" }
        qw(damage damage_capped hitplace health_before health_after damage_applied matchid half game_time event_epoch sequence));
    return damage_line('"Shooter<7><STEAM_0:1:123><Allies>" triggered "damage" against '
        . '"Target<11><STEAM_0:1:456><Axis>" with "garand" ' . $tail);
}

my ($row, $status);

# --- live match ------------------------------------------------------------------
$now = 1790000000;
marker_line("KTP_MATCH_START (matchid \"$MID\") (map \"dod_anzio\") (half \"1st\") (type \"0\")");
ok(defined($g_ktpMatchContext{$s_addr}), "KTP_MATCH_START opens a match context");
is($g_ktpMatchContext{$s_addr}{round_live}, 1, "a new match context starts round_live=1");
ok($ktp_matches{$MID}{1}, "control: MATCH_START wrote the half-1 interval the resolver reads");
is(frag_match_id(), "'$MID'", "live round: a frag is tagged with the match");
$now += 400;

# Seed the capture-health state the shipped reject counter writes into.
$g_ktpCaptureSequences{join("\x1e", $s_addr, $MID, 1)} =
    { seq => {}, received => 0, types => {}, rejected => {}, correlation_failures => {} };

# --- freeze ----------------------------------------------------------------------
marker_line("KTP_ROUND_FREEZE (matchid \"$MID\")");
is($g_ktpMatchContext{$s_addr}{round_live}, 0, "KTP_ROUND_FREEZE sets round_live=0");
is($ev_type, 603, "KTP_ROUND_FREEZE is event type 603");
is(frag_match_id(), 'NULL', "freeze: a frag is untagged (intended)");

$status = flag_state(owner => 1);
$row = flag_row();
ok($row, "freeze: a flag state with a proven producer context is written") or diag($status);
is($row && $row->{match_id}, $MID, "freeze: the flag state carries the producer match_id");
is($row && $row->{half}, 1, "freeze: the flag state carries the producer half");
like($status, qr/^Flag state logged/, "freeze: flag state status is logged");

$status = flag_state(owner => 0, initial => 0, sequence => 32, event_epoch => $now - 1);
$row = flag_row();
is($row && $row->{owner}, 0, "freeze: the reset to the default owner lands too") or diag($status);

($row, $status) = damage();
ok($row, "freeze: a buffered damage line produces one INSERT") or diag($status);
is($row && $row->{match_id}, "'$MID'", "freeze: late damage with a proven producer context keeps its match_id");
is($row && $row->{half}, 1, "freeze: late damage keeps its producer half");

# Sentinel context ('-'): the legacy receipt-time gate still decides, and it is closed.
($row, $status) = damage(matchid => '-', half => 0, sequence => 0);
is($row && $row->{match_id}, 'NULL', "freeze: damage without producer context stays untagged");

# A producer context that fails validation falls back to the gate, which is closed,
# and the drop reaches capture health instead of vanishing.
$status = flag_state(event_epoch => $now + 3600, sequence => 33);
ok(!flag_row(), "freeze: a flag state whose producer context fails validation is not written");
like($status, qr/dropped/i, "freeze: that flag state reports as dropped");
is($g_ktpCaptureSequences{join("\x1e", $s_addr, $MID, 1)}{rejected}{flag_state}, 1,
    "the dropped flag state is counted in capture health");
ok((grep { /FLAG_STATE_CLOCK_DROP/ } @logged), "the failed producer context is logged");

# A producer map that disagrees with the interval is not a proof either.
$status = flag_state(map => 'dod_avalanche', sequence => 34);
ok(!flag_row(), "freeze: a flag state whose map disagrees with the interval is not written");

# A legacy producer (no matchid at all) during the freeze: gate closed, dropped.
$status = flag_state(matchid => undef, half => undef, sequence => undef);
ok(!flag_row(), "freeze: a legacy flag state is still gated by round_live");
like($status, qr/dropped/i, "freeze: the legacy drop matches the reject classifier");

# --- live again ------------------------------------------------------------------
$now += 10;
marker_line("KTP_ROUND_LIVE (matchid \"$MID\")");
is($g_ktpMatchContext{$s_addr}{round_live}, 1, "KTP_ROUND_LIVE sets round_live=1");
is(frag_match_id(), "'$MID'", "live again: a frag is tagged");
$status = flag_state(matchid => undef, half => undef, sequence => undef);
$row = flag_row();
is($row && $row->{match_id}, $MID, "live again: a legacy flag state is tagged by receipt context") or diag($status);

# --- live round, a producer context that cannot be proved ---------------------------
# Every clock-failure case above runs during the FREEZE, where the receipt-time gate
# is closed and the handler refuses for its own reason -- so none of them can see
# whether the handler itself refuses. Inside a LIVE round the gate is open and the
# fall-through is reachable: an unprovable producer context used to be warned about
# and then written anyway, from daemon memory, stamped FROM_UNIXTIME(0).
#
# Both sides of the floor are seeded here on purpose. Without the sound row the
# refusals would pass over a dead harness; without the live-gate assertions they
# would pass for the freeze's reason rather than the handler's.
my $CKEY = join("\x1e", $s_addr, $MID, 1);
is($g_ktpMatchContext{$s_addr}{round_live}, 1,
    "non-vacuity: the round is live, so the legacy fall-through is OPEN here");
is($g_ktpMatchContext{$s_addr}{match_id}, $MID,
    "non-vacuity: daemon memory holds a match the fall-through could have borrowed");

$status = flag_state(owner => 2, sequence => 50, event_epoch => $now - 5);
$row = flag_row();
is($row && $row->{match_id}, $MID,
    "non-vacuity: a SOUND producer clock in the same live round still writes its row") or diag($status);
ok((grep { /FROM_UNIXTIME\(\d*[1-9]\d*\)/ } @sql),
    "non-vacuity: the sound row's event_time is a real clock, not the epoch");

# event_epoch 0 is the defect's own input: the producer reported no clock at all.
is(ktpValidateProducerEventClock($MID, 1, '402.00', 0), 'invalid event_epoch',
    "non-vacuity: the shipped validator really does refuse this clock");
my $rejected_before = $g_ktpCaptureSequences{$CKEY}{rejected}{flag_state} || 0;
ok($rejected_before > 0, "non-vacuity: the reject counter is live and already counting");
# The shipped warner aggregates after the first occurrence per (server, marker, error),
# so clear its state rather than asserting on a line it may legitimately suppress.
%g_ktpCaptureClockWarnings = ();
@logged = ();
$status = flag_state(owner => 1, sequence => 51, event_epoch => 0, game_time => '402.00');
ok(!flag_row(), "live round: a flag state whose producer clock is unusable is not written")
    or diag($status);
unlike(join('', @sql), qr/FROM_UNIXTIME\(0\)/,
    "live round: no flag-state row is stamped FROM_UNIXTIME(0)");
like($status, qr/dropped/i, "live round: that refusal reports as dropped");
ok((grep { /FLAG_STATE_CLOCK_DROP/ } @logged), "live round: the clock refusal reaches the journal");
is($g_ktpCaptureSequences{$CKEY}{rejected}{flag_state}, $rejected_before + 1,
    "live round: the refused row is counted in capture health, not lost silently");

# A matchid the interval table cannot prove must not be re-attributed to whatever
# match the daemon happens to be holding.
my $UNPROVEN = 'KTP-7-1790009999';
ok(!exists($ktp_matches{$UNPROVEN}),
    "non-vacuity: the unproven matchid really has no interval row");
ok(!exists($g_ktpCaptureSequences{join("\x1e", $s_addr, $UNPROVEN, 1)}),
    "non-vacuity: this harness seeded no capture context for the unproven matchid");
# The id must be well FORMED, or this measures the charset reject instead of the
# missing interval -- the same drift the clock case is pinned against above.
is(ktpValidateProducerEventClock($UNPROVEN, 1, '403.00', $now - 4), '',
    "non-vacuity: the unproven matchid passes envelope validation, so it reaches the DB proof");
%g_ktpCaptureClockWarnings = ();
@logged = ();
$status = flag_state(owner => 0, sequence => 52, matchid => $UNPROVEN, event_epoch => $now - 4);
$row = flag_row();
ok(!$row, "live round: a producer matchid with no interval is not written") or diag($status);
like($status, qr/event-time match intervals/,
    "live round: refused for the MISSING INTERVAL, not a malformed id");
isnt($row && $row->{match_id}, $MID,
    "live round: an unprovable producer matchid is not re-attributed to daemon memory");
# ktpRejectCaptureMarker keys on an OBSERVED context, so an unobservable matchid
# cannot increment it -- for that refusal the journal line is the only record.
ok((grep { /FLAG_STATE_CLOCK_DROP/ } @logged),
    "live round: a refusal with no observed context is still visible in the journal");

# --- freeze then MATCH_START --------------------------------------------------------
marker_line("KTP_ROUND_FREEZE (matchid \"$MID\")");
marker_line("KTP_MATCH_START (matchid \"$MID\") (map \"dod_anzio\") (half \"1st\") (type \"0\")");
is($g_ktpMatchContext{$s_addr}{round_live}, 1, "freeze then KTP_MATCH_START: round_live=1");

# --- freeze then HALF_END -----------------------------------------------------------
marker_line("KTP_ROUND_FREEZE (matchid \"$MID\")");
$now += 5;
marker_line("KTP_HALF_END (matchid \"$MID\") (map \"dod_anzio\") (half \"1st\")");
ok(!exists($g_ktpMatchContext{$s_addr}), "freeze then KTP_HALF_END: the context is deleted");
is(frag_match_id(), 'NULL', "after HALF_END: a frag is untagged");
($row, $status) = damage(event_epoch => $now - 4, sequence => 40);
is($row && $row->{match_id}, "'$MID'", "after HALF_END: damage buffered inside the half keeps its match_id");
$status = flag_state(event_epoch => $now - 4, sequence => 41);
$row = flag_row();
is($row && $row->{match_id}, $MID, "after HALF_END: a flag state from inside the half keeps its match_id") or diag($status);
$status = flag_state(event_epoch => $now + 60, sequence => 42);
ok(!flag_row(), "after HALF_END: a flag state stamped after the half closed is not written");

# --- freeze with no context ---------------------------------------------------------
%g_ktpMatchContext = ();
marker_line("KTP_ROUND_FREEZE (matchid \"$MID\")");
ok(!exists($g_ktpMatchContext{$s_addr}), "freeze with no context is a no-op (no context invented)");
marker_line("KTP_ROUND_LIVE (matchid \"$MID\")");
ok(!exists($g_ktpMatchContext{$s_addr}), "live with no context is a no-op");

done_testing();
