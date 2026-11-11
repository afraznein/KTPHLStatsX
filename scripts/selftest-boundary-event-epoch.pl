#!/usr/bin/perl
# A half's boundaries come from the producer's clock, not from when the daemon
# got round to reading them.
#
# Capture events carry the producer's event_epoch and are proved against the
# half's [start_time, end_time]. start_time was this daemon's NOW() at the moment
# it processed KTP_MATCH_START, so an ingest backlog of a second or more put the
# go-live snapshot before the half's start, and every one of those rows was
# rejected as "found 0 event-time match intervals". KTPMatchHandler now appends
# (event_epoch "N") to KTP_MATCH_START and KTP_HALF_END; this file holds the
# daemon to using it, to falling back to NOW() when it is absent or implausible,
# and to leaving the replayed-half reopen exactly as it was.
#
# The shipped source is lifted and run against a one-table fake of ktp_matches
# that evaluates the boundary expressions the handlers write:
#   - ktpBoundaryTimeSql / ktpBoundaryEndSql   hlstats.pl
#   - doEvent_KTPMatchStart / doEvent_KTPHalfEnd hlstats.pl
#   - ktpReopenReplayedHalfInterval            hlstats.pl
#   - ktpResolveProducerEventContext           hlstats.pl   (the rejection itself)
#   - getProperties, parseHalfNumber           hlstats.pl
#   - ktpValidMapName                          HLstats.plib
#
#   perl scripts/selftest-boundary-event-epoch.pl        # exit 0 = pass
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

# The lifted code reads time(); compiled after this, so it sees the fake clock.
our $NOW;
BEGIN { *CORE::GLOBAL::time = sub () { return $NOW; }; }

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

sub file_scope_number {
    my ($name) = @_;
    my ($v) = ($SOURCE{'hlstats.pl'} =~ /^our \$\Q$name\E\s*=\s*(\d+)\s*;/m);
    return $v;
}

# --- the bounds, read from the shipped source -----------------------------------
my $LAG  = file_scope_number('KTP_BOUNDARY_EPOCH_MAX_LAG');
my $LEAD = file_scope_number('KTP_BOUNDARY_EPOCH_MAX_LEAD');
is($LAG, 120, 'the backlog bound is 120 s, pinned here and not only in the source');
is($LEAD, 2, 'the lead bound is 2 s');
my ($above_loop) = ($SOURCE{'hlstats.pl'} =~ /(.*?)^while \(\$loop = &getLine\(\)\) \{/ms);
like($above_loop, qr/^our \$KTP_BOUNDARY_EPOCH_MAX_LAG/m,
    'and both are assigned above the main loop, which never exits in daemon mode');
like($above_loop, qr/^our \$KTP_BOUNDARY_EPOCH_MAX_LEAD/m, 'the lead bound too');

# --- collaborators --------------------------------------------------------------
our (%g_servers, %g_ktpMatchContext, %g_ktpProducerContextCache, $s_addr,
     @sql, @alarms, @logged, $KTP_REPLAY_REOPEN_MAX_AGE,
     $KTP_BOUNDARY_EPOCH_MAX_LAG, $KTP_BOUNDARY_EPOCH_MAX_LEAD);
$s_addr = '127.0.0.1:27015';
$KTP_REPLAY_REOPEN_MAX_AGE = file_scope_number('KTP_REPLAY_REOPEN_MAX_AGE');
$KTP_BOUNDARY_EPOCH_MAX_LAG = $LAG;
$KTP_BOUNDARY_EPOCH_MAX_LEAD = $LEAD;
%g_servers = ($s_addr => { id => 42 });

sub quoteSQL { my ($v) = @_; $v =~ s/\\/\\\\/g; $v =~ s/'/\\'/g; return $v; }
sub printEvent {
    push(@logged, join(' ', map { defined($_) ? $_ : '' } @_[0, 1]));
    return 1;
}
sub printAlarm { push(@alarms, join(' ', @_)); return 1; }

# One-table fake of ktp_matches. It evaluates exactly the boundary expressions
# the handlers can write, and dies on anything else, so a new expression cannot
# slip through as a silently ignored statement.
our %ROWS;    # "$match\x1e$half" => { map_name, start, end }

sub eval_time {
    my ($expr, $row) = @_;
    $expr =~ s/^\s+|\s+$//g;
    return $NOW if ($expr eq 'NOW()');
    return $1 if ($expr =~ /^FROM_UNIXTIME\((\d+)\)$/);
    if ($expr =~ /^GREATEST\(start_time, (.*)\)$/) {
        my $t = eval_time($1, $row);
        return ($row->{start} > $t) ? $row->{start} : $t;
    }
    die "fake ktp_matches cannot evaluate time expression: $expr";
}

sub execNonQuery {
    my ($q) = @_;
    push(@sql, $q);
    if ($q =~ /INSERT INTO ktp_matches .*VALUES \('([^']*)', \d+, '([^']*)', (\d+), [^,]+, (.*?)\)\s*ON DUPLICATE KEY/s) {
        my ($m, $map, $h, $start) = ($1, $2, $3, $4);
        my $k = "$m\x1e$h";
        $ROWS{$k} = { map_name => $map, start => eval_time($start, {}), end => undef }
            if (!exists($ROWS{$k}));
        return 1;
    }
    if ($q =~ /UPDATE ktp_matches\s+SET end_time = (.*?)\s+WHERE (.*)$/s) {
        my ($expr, $where) = ($1, $2);
        my ($m) = ($where =~ /match_id = '([^']*)'/);
        my ($h) = ($where =~ /half = (\d+)/);
        my $k = "$m\x1e$h";
        return '0E0' if (!exists($ROWS{$k}));
        my $row = $ROWS{$k};
        if ($where =~ /end_time IS NOT NULL/) {
            return '0E0' if (!defined($row->{end}));
        } elsif ($where =~ /end_time IS NULL/) {
            return '0E0' if (defined($row->{end}));
        }
        $row->{end} = ($expr eq 'NULL') ? undef : eval_time($expr, $row);
        return 1;
    }
    die "fake ktp_matches cannot execute: $q";
}

{
    package BoundaryFakeResult;
    sub new { my ($class, $rows) = @_; return bless({ rows => [@$rows] }, $class); }
    sub fetchrow_hashref { my ($self) = @_; return shift(@{$self->{rows}}); }
    sub finish { return 1; }
}
sub doQuery {
    my ($q) = @_;
    my ($m) = ($q =~ /match_id = '([^']*)'/);
    if ($q =~ /AND half = (\d+)\s+AND end_time IS NOT NULL/) {    # the replay reopen
        my $row = $ROWS{"$m\x1e$1"};
        return BoundaryFakeResult->new([]) if (!$row || !defined($row->{end}));
        return BoundaryFakeResult->new([{ map_name => $row->{map_name},
            start_epoch => $row->{start}, end_epoch => $row->{end}, now_epoch => $NOW }]);
    }
    if ($q =~ /start_time <= FROM_UNIXTIME\((\d+)\)/) {             # the resolver
        my $e = $1;
        my @hits;
        foreach my $k (sort keys %ROWS) {
            my ($rm, $rh) = split(/\x1e/, $k);
            next if ($rm ne $m);
            my $row = $ROWS{$k};
            next if ($row->{start} > $e);
            next if (defined($row->{end}) && $row->{end} < $e);
            push(@hits, { match_id => $rm, half => $rh, map_name => $row->{map_name},
                start_epoch => $row->{start}, end_epoch => $row->{end}, proof_epoch => $NOW });
        }
        return BoundaryFakeResult->new(\@hits);
    }
    die "fake ktp_matches cannot answer: $q";
}

# --- the shipped code under test ------------------------------------------------
my $lifted = body_of('HLstats.plib', 'ktpValidMapName')
    . body_of('hlstats.pl', 'getProperties')
    . body_of('hlstats.pl', 'parseHalfNumber')
    . body_of('hlstats.pl', 'ktpBoundaryTimeSql')
    . body_of('hlstats.pl', 'ktpBoundaryEndSql')
    . body_of('hlstats.pl', 'ktpReopenReplayedHalfInterval')
    . body_of('hlstats.pl', 'doEvent_KTPMatchStart')
    . body_of('hlstats.pl', 'doEvent_KTPHalfEnd')
    . body_of('hlstats.pl', 'ktpResolveProducerEventContext');
eval "no strict 'vars';\n$lifted\n1;" or die "lifted source did not compile: $@";
unlike($lifted, qr/selftest_sentinel_not_in_source/,
    'control: a token in no source file does not match the lift');

my $MATCH = '1794365828-NY1';
my $MAP   = 'dod_anzio';
my $GO    = 1794365000;    # the producer's go-live second

sub fresh {
    %ROWS = ();
    %g_ktpProducerContextCache = ();
    %g_ktpMatchContext = ();
    %g_servers = ($s_addr => { id => 42 });
    @sql = (); @alarms = (); @logged = ();
}
sub start_half {
    my ($half, $epoch, $processed_at) = @_;
    local $NOW = $processed_at;
    @sql = (); @alarms = ();
    doEvent_KTPMatchStart($MATCH, $MAP, $half, 4, $epoch);
}
sub end_half {
    my ($half, $epoch, $processed_at) = @_;
    local $NOW = $processed_at;
    @sql = (); @alarms = ();
    doEvent_KTPHalfEnd($MATCH, $MAP, $half, $epoch);
}
sub resolve {
    my ($epoch, $at) = @_;
    local $NOW = $at;
    %g_ktpProducerContextCache = ();
    my ($h, undef, $err) = ktpResolveProducerEventContext($MATCH, 1, $epoch);
    return $err eq '' ? "half $h" : $err;
}

# --- 1. the parse: the producer's line, through the shipped getProperties ---------
my %p = getProperties('(matchid "1794365828-NY1") (map "dod_anzio") (half "1st") (type "4") (event_epoch "1794365000")');
is($p{matchid}, '1794365828-NY1', 'the new line still yields matchid');
is($p{map}, 'dod_anzio', 'and map');
is($p{half}, '1st', 'and half');
is($p{type}, '4', 'and type, unchanged by the appended property');
is($p{event_epoch}, '1794365000', 'and the epoch');
%p = getProperties('(matchid "1794365828-NY1") (map "dod_anzio") (half "1st")');
ok(!defined($p{event_epoch}), 'an old producer line carries no epoch at all');

# Both dispatch paths hand the epoch on; a path that drops it is a silent no-op.
my $src = $SOURCE{'hlstats.pl'};
my @start_calls = ($src =~ /(&doEvent_KTPMatchStart\(.*?\);)/gs);
my @end_calls   = ($src =~ /(&doEvent_KTPHalfEnd\(.*?\);)/gs);
is(scalar(@start_calls), 2, 'control: two dispatch sites call doEvent_KTPMatchStart');
is(scalar(@end_calls), 2, 'control: two dispatch sites call doEvent_KTPHalfEnd');
is(scalar(grep { /\$ev_properties\{"event_epoch"\}/ } @start_calls), 2,
    'both pass event_epoch to the match start');
is(scalar(grep { /\$ev_properties\{"event_epoch"\}/ } @end_calls), 2,
    'both pass event_epoch to the half end');

# --- 2. the late-processing case: what the card measured, then the fix ------------
# NY1 h1 on 11-10: the daemon read KTP_MATCH_START 25 s after the producer wrote
# it. The go-live snapshot is stamped at the producer's go-live second.
fresh();
start_half('1st', undef, $GO + 25);    # what the live producer sends today
is($ROWS{"$MATCH\x1e1"}{start}, $GO + 25, 'with no epoch, start_time is the late NOW()');
like(resolve($GO, $GO + 30), qr/found 0 event-time match intervals/,
    'and the go-live snapshot is rejected: the defect, reproduced');
like($sql[-1], qr/, NOW\(\)\)\s*ON DUPLICATE KEY/,
    'the old producer still gets exactly the old SQL');

fresh();
start_half('1st', $GO, $GO + 25);
is($ROWS{"$MATCH\x1e1"}{start}, $GO, 'with the epoch, start_time is the producer second');
is(resolve($GO, $GO + 30), 'half 1', 'and the same snapshot now resolves to its half');
is(resolve($GO + 600, $GO + 630), 'half 1', 'as does a mid-half event');
like(resolve($GO - 1, $GO + 30), qr/found 0 event-time match intervals/,
    'while an event a second before go-live is still outside the half');
is(scalar(@alarms), 0, 'a 25 s backlog is inside the bound and raises nothing');

# --- 3. the bound, both sides of each edge ----------------------------------------
fresh();
start_half('1st', $GO, $GO + $LAG);
is($ROWS{"$MATCH\x1e1"}{start}, $GO, 'exactly at the backlog bound the epoch is used');
fresh();
start_half('1st', $GO, $GO + $LAG + 1);
is($ROWS{"$MATCH\x1e1"}{start}, $GO + $LAG + 1, 'one second past it, NOW() is');
is(scalar(@alarms), 1, 'and that fallback is reported once');
like($alarms[0], qr/KTP_BOUNDARY_CLOCK.*KTP_MATCH_START \Q$MATCH\E half 1.*'$GO'/,
    'naming the line, the match and the rejected epoch');

fresh();
start_half('1st', $GO + $LEAD, $GO);
is($ROWS{"$MATCH\x1e1"}{start}, $GO,
    'an epoch just ahead is held to NOW(), never a start in the future');
is(scalar(@alarms), 0, 'silently: truncating to whole seconds alone puts it a second ahead');
fresh();
start_half('1st', $GO + $LEAD + 1, $GO);
is($ROWS{"$MATCH\x1e1"}{start}, $GO, 'past the lead bound it is NOW() as well');
is(scalar(@alarms), 1, 'but that one is reported');

foreach my $bad ('', 'abc', '0', '-5', '1794365000.5', '0123') {
    fresh();
    start_half('1st', $bad, $GO + 5);
    is($ROWS{"$MATCH\x1e1"}{start}, $GO + 5, "a malformed epoch '$bad' falls back to NOW()");
}

# --- 4. the half end ----------------------------------------------------------------
fresh();
start_half('1st', $GO, $GO + 1);
end_half('1st', $GO + 1300, $GO + 1320);
is($ROWS{"$MATCH\x1e1"}{end}, $GO + 1300, 'the half closes at the producer second');
like($sql[-1], qr/SET end_time = GREATEST\(start_time, FROM_UNIXTIME\(\d+\)\)/,
    'bounded below by its own start');
is(resolve($GO + 1300, $GO + 1330), 'half 1', 'an event in the last second still resolves');
like(resolve($GO + 1301, $GO + 1330), qr/found 0/, 'one after it does not');

fresh();
start_half('1st', undef, $GO + 1);
end_half('1st', undef, $GO + 1320);
like($sql[-1], qr/SET end_time = NOW\(\)\n/, 'an old producer still gets exactly NOW()');

# An end from the producer must never precede a start this daemon stamped late.
fresh();
start_half('1st', $GO, $GO + $LAG + 30);    # start fell back: stamped at GO+150
end_half('1st', $GO + 100, $GO + 140);
is($ROWS{"$MATCH\x1e1"}{end}, $ROWS{"$MATCH\x1e1"}{start},
    'an end earlier than a late-stamped start is held to the start');

# Half 2 closing a half 1 whose KTP_HALF_END was lost uses the same clock.
fresh();
start_half('1st', $GO, $GO + 1);
start_half('2nd', $GO + 1500, $GO + 1510);
is($ROWS{"$MATCH\x1e1"}{end}, $GO + 1500, 'a lost half end is closed at the next start');
is($ROWS{"$MATCH\x1e2"}{start}, $GO + 1500, 'which is also where half 2 begins');

# --- 5. the replay reopen is unchanged ----------------------------------------------
# It runs before the upsert and reads start_time for its age bound. The upsert
# still never refreshes start_time, so a replayed half keeps its first start.
fresh();
start_half('1st', $GO, $GO + 3);
end_half('1st', $GO + 8, $GO + 9);     # aborted eight seconds in
start_half('1st', $GO + 20, $GO + 45); # replayed, read 25 s late
is($ROWS{"$MATCH\x1e1"}{start}, $GO, 'a replay keeps the first start_time');
ok(!defined($ROWS{"$MATCH\x1e1"}{end}), 'and is reopened');
ok(scalar(grep { /Match interval reopened/ } @logged), 'and says so');
is(resolve($GO + 1336, $GO + 1340), 'half 1', 'so a late event in the replay resolves');

my $upsert = body_of('hlstats.pl', 'doEvent_KTPMatchStart');
my ($on_dup) = ($upsert =~ /ON DUPLICATE KEY UPDATE(.*?)"\s*\)/s);
unlike($on_dup, qr/start_time/, 'control: the upsert still does not refresh start_time');
my $reopen_at = index($upsert, '&ktpReopenReplayedHalfInterval(');
my $insert_at = index($upsert, 'INSERT INTO ktp_matches');
ok($reopen_at > 0 && $insert_at > $reopen_at, 'and the reopen still runs before it');

# A reused id on another map still refuses, whatever clock the new start carries.
fresh();
$ROWS{"$MATCH\x1e1"} = { map_name => 'dod_halle', start => $GO - 86400 * 30,
    end => $GO - 86400 * 30 + 1300 };
start_half('1st', $GO, $GO + 4);
ok(defined($ROWS{"$MATCH\x1e1"}{end}), 'a reused id on another map is not reopened');
ok(scalar(grep { /Declined to reopen/ } @logged), 'and the refusal is reported');
like(resolve($GO, $GO + 10), qr/found 0/, 'so its events still fail closed');

done_testing();
