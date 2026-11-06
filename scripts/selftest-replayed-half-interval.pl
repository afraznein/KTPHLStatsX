#!/usr/bin/perl
# A half that starts again gets an interval that holds its own events.
#
# The upsert in doEvent_KTPMatchStart refreshes neither boundary, so a half
# replayed after its interval closed kept the aborted interval: an eight-second
# window in front of a twenty-two-minute half. Every event-time-gated stream in
# that half then resolved no interval and was dropped, and a half played without
# an interval cannot be re-derived afterwards -- the rows are simply absent.
#
# A reused match_id inheriting a stale interval is the shape that resembles this
# one and must keep failing closed, so both directions of the reopen bound are
# asserted here: the replay is reopened, the inherited interval is refused and
# says why.
#
# The shipped source is lifted and run, so a fix that is reverted or paraphrased
# fails here:
#   - ktpReopenReplayedHalfInterval   hlstats.pl
#   - doEvent_KTPMatchStart           hlstats.pl   (call order against the upsert)
#   - ktpResolveProducerEventContext  hlstats.pl   (the dropped-stream symptom)
#   - parseHalfNumber                 hlstats.pl
#   - ktpValidMapName                 HLstats.plib
#
#   perl scripts/selftest-replayed-half-interval.pl        # exit 0 = pass
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

my %SOURCE = (
    'hlstats.pl'   => slurp("$DIR/hlstats.pl"),
    'HLstats.plib' => slurp("$DIR/HLstats.plib"),
);

sub body_of {
    my ($file, $name) = @_;
    my ($body) = ($SOURCE{$file} =~ /\nsub \Q$name\E\s*\{(.*?)\n\}/s);
    die "could not extract sub $name from $file" if (!defined($body));
    return "sub $name {$body\n}\n";
}

# --- the session-age bound, read from the shipped source ------------------------
my ($bound_line) = ($SOURCE{'hlstats.pl'}
    =~ /^our \$KTP_REPLAY_REOPEN_MAX_AGE\s*=\s*(\d+)\s*;/m);
ok(defined($bound_line), 'the session-age bound is assigned at file scope');
is($bound_line, 21600, 'and its value is pinned here, not only in the source');

my ($loop_at) = ($SOURCE{'hlstats.pl'} =~ /(.*?)^while \(\$loop = &getLine\(\)\) \{/ms);
like($loop_at, qr/^our \$KTP_REPLAY_REOPEN_MAX_AGE/m,
    'and it is above the main loop, which never exits in daemon mode');

# --- collaborators --------------------------------------------------------------
our (%g_servers, %g_ktpMatchContext, %g_ktpProducerContextCache,
     $s_addr, @sql, @queries, @query_rows, @logged, $exec_return,
     $KTP_REPLAY_REOPEN_MAX_AGE);
$s_addr = '127.0.0.1:27015';
$KTP_REPLAY_REOPEN_MAX_AGE = $bound_line;
$exec_return = 1;
%g_servers = ($s_addr => { id => 42 });

sub quoteSQL { my ($v) = @_; $v =~ s/\\/\\\\/g; $v =~ s/'/\\'/g; return $v; }
sub execNonQuery { push(@sql, $_[0]); return $exec_return; }
sub printEvent {
    push(@logged, join(' ', map { defined($_) ? $_ : '' } @_[0, 1]));
    return 1;
}
sub printAlarm { return 1; }

{
    package ReplayFakeResult;
    sub new { my ($class, $rows) = @_; return bless({ rows => [@$rows] }, $class); }
    sub fetchrow_hashref { my ($self) = @_; return shift(@{$self->{rows}}); }
    sub finish { return 1; }
}
sub doQuery {
    push(@queries, $_[0]);
    return ReplayFakeResult->new(\@query_rows);
}

# --- the shipped code under test ------------------------------------------------
my $lifted = body_of('HLstats.plib', 'ktpValidMapName')
    . body_of('hlstats.pl', 'parseHalfNumber')
    . body_of('hlstats.pl', 'ktpReopenReplayedHalfInterval')
    . body_of('hlstats.pl', 'doEvent_KTPMatchStart')
    . body_of('hlstats.pl', 'ktpResolveProducerEventContext');
eval "no strict 'vars';\n$lifted\n1;" or die "lifted source did not compile: $@";

# Controls on the lift. The reopen exists BECAUSE the upsert refreshes neither
# boundary; if that ever changes, these assertions stop describing the code and
# the rest of this file is measuring a defect that is no longer there.
my $upsert = body_of('hlstats.pl', 'doEvent_KTPMatchStart');
like($upsert, qr/ON DUPLICATE KEY UPDATE/,
    'control: the match row is still written by an upsert');
my ($on_dup) = ($upsert =~ /ON DUPLICATE KEY UPDATE(.*?)"\s*\)/s);
ok(defined($on_dup), 'control: the upsert has a duplicate-key clause to read');
unlike($on_dup, qr/start_time/,
    'control: and it still refreshes neither start_time');
unlike($on_dup, qr/end_time/, 'control: nor end_time');
unlike($lifted, qr/selftest_sentinel_not_in_source/,
    'control: a token that is in no source file does not match the lift');

my $reopen_src = body_of('hlstats.pl', 'ktpReopenReplayedHalfInterval');
like($reopen_src, qr/SET end_time = NULL/, 'the reopen clears end_time');
unlike($reopen_src, qr/SET[^"]*start_time/,
    'and never assigns start_time: the half owns events before the replay');

# --- the measured signature -----------------------------------------------------
# An eight-second interval in front of a half whose markers run twenty-two
# minutes past it, on the map the half is actually being played on.
my $START      = 1793000000;
my $ABORTED_AT = $START + 8;
my $REPLAY_AT  = $START + 20;
my $LATE_EVENT = $START + 1336;
my $MAP        = 'dod_lennon5_b1';
my $MATCH      = '1.3-6904-NY1';

sub closed_row {
    my (%over) = @_;
    return {
        map_name    => $MAP,
        start_epoch => $START,
        end_epoch   => $ABORTED_AT,
        now_epoch   => $REPLAY_AT,
        %over,
    };
}

sub reopen {
    my ($rows, $map) = @_;
    @sql = ();
    @queries = ();
    @logged = ();
    @query_rows = @$rows;
    return ktpReopenReplayedHalfInterval($MATCH, defined($map) ? $map : $MAP, 1, 42);
}

# --- 1. the symptom, through the shipped resolver -------------------------------
# Interval containment is decided in SQL, so the fixture is the row set that
# query would return: nothing, while the aborted interval is the only row.
%g_ktpProducerContextCache = ();
@query_rows = ();
my (undef, undef, $error, undef) =
    ktpResolveProducerEventContext($MATCH, 1, $LATE_EVENT);
like($error, qr/found 0 event-time match intervals/,
    'while the aborted interval stands, a late event in the half resolves nothing');

# The same event against the reopened row: end_time is NULL, so the interval is
# open and the event is inside it.
%g_ktpProducerContextCache = ();
@query_rows = ({ match_id => $MATCH, half => 1, map_name => $MAP,
    start_epoch => $START, end_epoch => undef, proof_epoch => $LATE_EVENT + 1 });
my ($half, $map, $err2, $proof) =
    ktpResolveProducerEventContext($MATCH, 1, $LATE_EVENT);
is($err2, '', 'once reopened, the same event resolves');
is($half, 1, 'to its own half');
is($map, $MAP, 'and its own map');
is($proof, 'event-time-interval', 'proved against the persisted interval');

# --- 2. the reopen itself -------------------------------------------------------
is(reopen([closed_row()]), 'reopened',
    'a half re-entering on the same map, inside the session, is reopened');
is(scalar(@sql), 1, 'with exactly one write');
like($sql[0], qr/UPDATE ktp_matches/, 'against the match row');
like($sql[0], qr/SET end_time = NULL/, 'clearing only end_time');
like($sql[0], qr/AND half = 1\b/, 'for that half alone');
like($sql[0], qr/WHERE server_id = 42\b/, 'on that server alone');
ok(scalar(grep { /Match interval reopened/ } @logged),
    'and the reopen is reported rather than silent');
ok(scalar(grep { /the closed interval ran 8s/ } @logged),
    'naming the aborted interval length, the only forensic the daemon holds');

# A duplicate log line arrives while the interval is still open, so no closed
# row comes back. This is the case the no-op upsert was protecting.
is(reopen([]), 'no closed interval', 'a still-open interval is not touched');
is(scalar(@sql), 0, 'and nothing is written');
is(scalar(@logged), 0, 'and nothing is reported');

# --- 3. the shape that must keep failing closed ---------------------------------
# A reused match_id inherits an interval from an earlier month. The map is the
# independent discriminator: there, it disagrees.
is(reopen([closed_row(map_name => 'dod_halle')]),
    'map disagrees with closed interval',
    'an interval on another map is refused, not reopened');
is(scalar(@sql), 0, 'nothing is written for it');
ok(scalar(grep { /Declined to reopen/ && /dod_halle/ && /$MAP/ } @logged),
    'and the refusal names both maps, so a collision is loud');

# The same inheritance where the map happens to agree: session age refuses it.
is(reopen([closed_row(now_epoch => $START + 9 * 30 * 86400)]),
    'closed interval predates this session',
    'an interval older than one session is refused even when the map agrees');
is(scalar(@sql), 0, 'nothing is written for it either');
ok(scalar(grep { /Declined to reopen/ && /beyond one session/ } @logged),
    'and that refusal says which bound it failed');

# Both sides of the bound, so it discriminates rather than always passing.
is(reopen([closed_row(now_epoch => $START + $KTP_REPLAY_REOPEN_MAX_AGE)]),
    'reopened', 'exactly at the bound is still a replay');
is(reopen([closed_row(now_epoch => $START + $KTP_REPLAY_REOPEN_MAX_AGE + 1)]),
    'closed interval predates this session', 'one second past it is not');

# --- 4. refusals that are not about the bound -----------------------------------
is(reopen([closed_row(end_epoch => $START - 1)]),
    'closed interval has an unreadable clock',
    'an interval that ends before it starts is refused');
is(reopen([closed_row(start_epoch => undef)]),
    'closed interval has an unreadable clock', 'so is a missing start');
is(reopen([closed_row()], ''), 'map disagrees with closed interval',
    'a starting event with no map cannot match an interval');

{
    local $exec_return = '0E0';   # DBI's zero-rows-affected: true, but not a row
    is(reopen([closed_row()]), 'reopen failed',
        'a reopen that changed no row is not reported as a reopen');
    ok(!scalar(grep { /Match interval reopened/ } @logged),
        'and nothing claims it was reopened');
}
{
    local $exec_return = undef;   # execNonQuery on a failed statement
    is(reopen([closed_row()]), 'reopen failed', 'nor is a failed statement');
}

# --- 5. order, through the handler ----------------------------------------------
sub match_start {
    my ($rows) = @_;
    @sql = ();
    @queries = ();
    @logged = ();
    @query_rows = @$rows;
    %g_ktpMatchContext = ();
    %g_servers = ($s_addr => { id => 42 });
    doEvent_KTPMatchStart($MATCH, $MAP, '1', 0);
    return @sql;
}

my @wrote = match_start([closed_row()]);
is(scalar(@wrote), 2, 'a replayed half start issues the reopen and the upsert');
like($wrote[0], qr/SET end_time = NULL/,
    'the reopen runs FIRST -- after the upsert it would be reading its own write');
like($wrote[1], qr/INSERT INTO ktp_matches/, 'and the upsert second');

@wrote = match_start([]);
is(scalar(@wrote), 1, 'a first start writes only the row');
like($wrote[0], qr/INSERT INTO ktp_matches/, 'which is the insert');

# The handler must still reach a half-2 start the same way, and the prev-half
# close is a separate write that the reopen does not displace.
@sql = ();
@queries = ();
@query_rows = ();
%g_servers = ($s_addr => { id => 42 });
doEvent_KTPMatchStart($MATCH, $MAP, '2', 0);
is(scalar(grep { /SET end_time = NOW\(\)/ } @sql), 1,
    'half 2 still closes half 1');
is(scalar(grep { /INSERT INTO ktp_matches/ } @sql), 1, 'and still inserts its own row');
is(scalar(@queries), 1, 'and still asks whether its own half was closed before');

done_testing();
