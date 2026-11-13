#!/usr/bin/perl
#
# The move-census stream has to be named in NINE separate hand-maintained places
# in hlstats.pl. That is not hypothetical: `shot` was added to four of them and
# missed in the capture-health allow-list, which would have left the highest-volume
# stream of its wave with no drop detection at all, and nothing would have failed.
# This test is that miss, written down.
#
# It asserts on the shipped hlstats.pl text rather than running the daemon, the same
# way selftest-position-batching.pl does. A stream can be wired correctly and still be
# wrong, but it cannot be wired incorrectly and be right.
#
# Exact-text checks use index() with single-quoted needles on purpose: the strings
# being matched are full of $sigils, and a qr// would interpolate them into nothing
# and then pass against anything.

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $SRC = dirname($0) . '/hlstats.pl';
open(my $fh, '<', $SRC) or die "cannot read $SRC: $!";
my $source = do { local $/; <$fh> };
close($fh);
$source =~ s/\r//g;

sub body_of {
    my ($name) = @_;
    my ($body) = ($source =~ /sub \Q$name\E\s*\{(.*?)\n\}/s);
    die "could not extract sub $name from $SRC" if (!defined($body));
    return $body;
}

sub has {
    my ($haystack, $needle, $name) = @_;
    ok(index($haystack, $needle) >= 0, $name)
        or diag("missing literal: $needle");
}

sub hasnt {
    my ($haystack, $needle, $name) = @_;
    ok(index($haystack, $needle) < 0, $name)
        or diag("unexpected literal: $needle");
}

# --- 0. the needles themselves are real ------------------------------------
# A literal-substring test passes vacuously if the needle is misspelled in a way
# that never appears. Anchor on something that must already be there, and on
# something that must not be, so the harness is shown to discriminate.
has($source, 'sub doEvent_KTPShot', 'control: a known-present literal is found');
hasnt($source, 'sub doEvent_KTPZzzNoSuchHandler', 'control: an absent literal is not found');

# --- 1. the nine registration points ---------------------------------------
#
# The three whitelists are asserted as MEMBERSHIP in the alternation, not as a
# remembered tail of it. They were pinned as literal tails until the aim_vis
# stream was added, and all three broke at once -- a brittle needle on a shared
# list reports this stream as unregistered because a different one arrived.
# Each extraction carries a control so a regex that stopped matching cannot pass
# as an empty list.

#
# There are TWO whitelists of each shape -- one for the unbuffered streams and
# one for the buffered standalone markers -- so a member is asserted against ALL
# of them and has to appear in at least one. Taking only the first match reads
# the wrong list and reports the stream as unregistered.
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
    registered_in(\@obs, 'move_census',
        'move_census is in the capture-marker observation whitelist');
}
has($source, 'move_census => "move"',
    'move_census maps to the "move" sequence type');
{
    my @buf = ($source =~ /\$ev_obj_a =~ \/\^\(\?:([^)]*)\)\$\//g);
    registered_in(\@buf, 'move_census',
        'move_census is in the buffered-identity whitelist');
}
like($source, qr/\}\s*elsif\s*\(\$ev_obj_a\s+eq\s+"move_census"\)\s*\{/,
    'move_census has a dispatch branch');
has($source, 'move => $capabilities{move} ? 1 : 0',
    'the accepted-manifest record carries the move capability bit');
{
    my $auth = body_of('ktpCaptureManifestAuthorizes');
    my ($types) = (($auth // '') =~ /\$event_type !~ \/\^\(\?:([^)]*)\)\$\//);
    registered_in([defined($types) ? $types : ()], 'move',
        'ktpCaptureManifestAuthorizes accepts "move" as an event type');
}
# Deliberately NOT an assertion that a new schema ordinal was accepted. This
# stream takes none: the capability bit is the gate. 25 went to the ruled
# shooter_punch drop (KTPAMXX #144) and 26 to the ruled shot hitgroup + rewind
# bump, so pin the whitelist to exactly 21..26 -- anything widening it further
# has to name the ruled change that owns the ordinal.
{
    my $validator = body_of('ktpValidateCaptureManifestPayload');
    my ($clause) = (($validator // '') =~ /return "unsupported schema"(.*?);/s);
    my @ordinals = sort { $a <=> $b } (($clause // '') =~ /!= (\d+)/g);
    is(join(',', @ordinals), '21,22,23,24,25,26',
        'no schema ordinal was claimed for this stream; the capability bit gates it');
}

{
    my $resend = body_of('ktpResentLineIsRedundant');
    has($resend, 'move_census => "move"',
        'resent move_census lines are recognised (or every resend of one is dropped)');
}

{
    # The one that was missed for `shot`.
    my ($allowed) = ($source =~ /my %allowed = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    ok(defined($allowed), 'the capture-health allow-list was found');
    like($allowed // '', qr/\bmove\b/,
        'the capture-health allow-list names "move" -- the exact line `shot` was missed on');
}

{
    # The SAME class of miss, four lines further down, and the allow-list assertion
    # above does not catch it: a stream named in neither %always_active nor
    # %manifest_gated falls through the elsif and returns "" unconditionally, so it
    # can go dark forever with no warning. Being in the allow-list buys nothing if
    # the classification then declines to look.
    my ($gated) = ($source =~ /my %manifest_gated = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    my ($always) = ($source =~ /my %always_active = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    ok(defined($gated) && defined($always), 'the silent-stream classification sets were found');
    ok((($gated // '') =~ /\bmove\b/) || (($always // '') =~ /\bmove\b/),
        '"move" is classified for dead-producer detection, not left in neither set');
}

# --- 2. the handler's own contracts ----------------------------------------

my $body = body_of('doEvent_KTPMove');

{
    my ($success) = ($body =~ /return\s+("Move census logged[^"]*")/);
    ok(defined($success), 'the handler has a success return string');
    unlike($success // '', qr/dropped|failed/i,
        'the success string does not trip the call site /dropped|failed/i reject');
    like($source, qr/ktpRejectCaptureMarker\("move".{0,200}?dropped\|failed/s,
        'the call site rejects on the same classifier the handler avoids');
}

has($body, '$manifest->{schema} < 23 || !$manifest->{move}',
    'the handler refuses a manifest that does not authorise this stream');

has($body, '$raw !~ /\\S/',
    'an optional histogram present but EMPTY (plugin newer than its dodx) is stored as absent, not dropped');
has($body, 'scalar(@v) != $buckets',
    'a histogram with the wrong number of buckets is rejected, not padded');
hasnt($body, 'push(@v, 0)',
    'nothing pads a short histogram with zeros (a padded cell reads as a measurement)');

has($body, 'my $wire_sequence = (defined($p->{sequence})',
    'a missing producer sequence becomes SQL NULL rather than 0');
has($body, 'my $stam_min = "NULL";',
    'stam_tap_min has a NULL path -- 0 is a real stamina reading, so -1 must not be stored');

# \b after the table name, not a bare substring: without it this passes against
# ktp_move_census_anything, which is a different table.
like($body, qr/INSERT\s+IGNORE\s+INTO\s+ktp_move_census\b/,
    'the handler writes ktp_move_census with the INSERT IGNORE dedup contract');

has($body, 'Move census dropped: invalid game_time',
    'game_time is regex-guarded rather than left to Perl numification');
has($body, 'wider than the column',
    'a rendered histogram is bounded by the column it is stored in');
has($body, '$stam_min > 32767',
    'stam_tap_min is bounded to its column -- the module cannot clamp it, -1 is its sentinel');

# --- 3. the measure-only contract ------------------------------------------
#
# There is no positive class for this stream yet, so any comparison against a
# constant here would be a guessed gate. Assert that none appeared.

unlike($body, qr/(?:steps_ground|step_timer_fires|taps)\}?\s*[<>]=?\s*\d/,
    'the handler compares no counter against a threshold');
unlike($body, qr/\bsuspicious\b|\bverdict\b|\bcheat\b/i,
    'the handler reaches no conclusion about a player');

# --- 4. both halves stay in one row ----------------------------------------
#
# A footstep count read without the tap census beside it describes an ordinary
# crouch-walker exactly as well as it describes what this stream exists to look
# for. One INSERT is what stops the two being queried apart by accident.

my @inserts = ($body =~ /INSERT\s+IGNORE\s+INTO\s+ktp_move_census\b/g);
is(scalar(@inserts), 1,
    'the census is written as ONE row -- splitting it would make the footstep-only read easy');
for my $col (qw(taps taps_ground steps_ground step_timer_fires)) {
    has($body, $col, "the single INSERT carries $col");
}


# --- 5. the wire format actually parses -------------------------------------
#
# Everything above checks that the stream is WIRED UP. This checks that the line
# the producer emits can be READ, using the daemon's own getProperties rather
# than a reimplementation of it -- a copy would pass while the real parser
# choked. It also measures the worst-case width, because the producer's buffer
# truncates silently and a truncated line stops matching the dispatch regex
# without failing anywhere. That is how the life-boundary stream lost its
# sequence field.

{
    my ($fn) = $source =~ /^(sub getProperties\s*\{.*?^\})/ms;
    ok(defined($fn), 'getProperties was lifted out of hlstats.pl');
    eval "no strict 'vars';\n$fn\n1;" or die "could not load getProperties: $@";

    # The daemon's own player-verb dispatch regex.
    my $LINE_RE = qr/^"(.+?(?:<.+?>)*?)" ([a-zA-Z,_\s]+) "(.+?)"(.*)$/;

    # Mirrors KSC_BUF_LINE_LEN in KTPAMXX plugins/dod/ktp_stats_capture.inc.
    # Cross-repo, so it cannot be derived here -- if that constant shrinks, this
    # number has to follow it or the check stops meaning anything.
    my $KSC_BUF_LINE_LEN = 1024;
    # The ceiling that actually binds. The producer sends this line through
    # log_message(), and ReHLDS's Log_Printf formats into a 1,024-byte buffer that
    # already holds its "L mm/dd/yyyy - hh:mm:ss: " prefix (25 bytes), the trailing
    # newline and the terminator: 997 characters of line arrive whole, the rest are
    # cut. Pin against THIS, not the plugin buffer -- the 2026-10-20 derivation pinned
    # against 1,023 and shipped a worst case of 999.
    my $LOG_PRINTF_BUDGET = 1024 - 25 - 2;

    # The RESERVED ceiling, not the geometry shipping today. Testing today's six
    # buckets would pass while the producer reserves room for more than the line can
    # hold -- which is exactly the state this started in. Mirrors
    # KSC_MOVE_MAX_BUCKETS in KTPAMXX plugins/dod/ktp_stats_capture.inc.
    my $BUCKETS = 6;
    # KTPMove::WIRE_MAX, five digits since stats_logging 1.31.0 (was six). A 30 s
    # window cannot put more than 30,000 ms in a bucket and no count comes near it,
    # so the clamp still bounds every real value -- and each digit here is paid for
    # in every histogram against the Log_Printf ceiling below.
    my $big     = "99999";
    # A width placeholder, not a SteamID. Only its LENGTH matters here, and a
    # real-looking one in a committed fixture is identity-shaped material in a
    # public repo for no test value at all. The width is the ENGINE's worst case,
    # not the plugin's 96-byte buffer (which it cannot fill): MAX_NAME_LENGTH is 32,
    # so 31 name characters; the userid is an int the engine increments per connect
    # (seven digits is weeks of uptime); a SteamID is at most STEAM_0:1:4294967295,
    # 20 characters; the longest DoD team string is "Unassigned". 74 characters.
    my $pstr    = ("x" x 31) . "<9999999><STEAM_0:1:4294967295><Unassigned>";
    my $matchid = "m" x 63;
    my $map     = "dod_" . ("m" x 27);
    my $hist    = join(" ", ($big) x $BUCKETS);

    my $worst = sprintf(
        '"%s" triggered "move_census" (window_ms "%s") (buckets "%d") (bucket_width "%d")'
      . ' (taps "%s") (taps_ground "%s") (taps_air "%s") (ground_ms_standing "%s")'
      . ' (ground_ms_ducked "%s") (air_ms_ducked "%s") (stam_tap_sum "%s") (stam_tap_min "%d")'
      . ' (steps_ground "%s") (steps_ladder "%s") (sounds_water "%s") (pmove_sounds "%s")'
      . ' (step_timer_fires "%s") (steps_ducked "%s") (ground_ms_ducked_silent "%s")'
      . ' (air_ms_standing "%s")'
      . ' (map "%s") (matchid "%s") (half "%d") (game_time "%.2f")'
      . ' (event_epoch "%d") (sequence "%d")',
        $pstr, $big, $BUCKETS, 50, $big,
        $hist, $hist, $hist, $hist, $hist,
        $big, 0, $big, $big, $big, $big, $big,
        $hist, $hist, $hist,
        # sequence is a Pawn cell (ksc_next_type_sequence returns an int), so ten digits
        # is its ceiling; the nineteen used before were a bigint's, not the producer's.
        $map, $matchid, 2, 99999.99, 2147483647, 2147483647);

    diag("worst-case move_census line: " . length($worst) . " chars, budget " . ($KSC_BUF_LINE_LEN - 1));
    cmp_ok(length($worst), '<', $KSC_BUF_LINE_LEN - 1,
        'the worst-case line fits the producer buffer, terminator included');
    cmp_ok(length($worst), '<=', $LOG_PRINTF_BUDGET,
        'the worst-case line survives Log_Printf whole: 1,024 bytes less the 25-byte timestamp, newline and terminator');

    my @m = ($worst =~ $LINE_RE);
    ok(scalar(@m), 'the worst-case line matches the daemon dispatch regex');
    is($m[2], 'move_census', 'it dispatches as move_census');

    my %prop = getProperties($m[3]);
    for my $f (qw(window_ms buckets bucket_width taps taps_ground taps_air
                  ground_ms_standing ground_ms_ducked air_ms_ducked
                  stam_tap_sum stam_tap_min steps_ground steps_ladder
                  sounds_water pmove_sounds step_timer_fires
                  steps_ducked ground_ms_ducked_silent air_ms_standing map matchid
                  half game_time event_epoch sequence)) {
        ok(defined($prop{$f}), "the handler's field '$f' survives getProperties");
    }
    is(scalar(my @v = split(/\s+/, $prop{taps_ground})), $BUCKETS,
        'a histogram arrives with exactly `buckets` values');
    is($prop{map}, $map, 'map survives at full column width');
    is($prop{matchid}, $matchid, 'matchid survives at full column width');

    # getProperties drops an EMPTY quoted value, which is correct and is also the
    # trap: a legitimate zero must not be what disappears. Every field in this
    # stream can legitimately be zero.
    my %zero = getProperties('(air_ms_ducked "0 0 0 0 0 0") (taps "0") (stam_tap_min "0")');
    is($zero{air_ms_ducked}, "0 0 0 0 0 0", 'an all-zero histogram is a value, not an absence');
    is($zero{taps}, "0", 'a zero tap count is a value, not an absence');
    is($zero{stam_tap_min}, "0", 'a stamina of 0 at a tap is a value, not an absence');
}

# --- 6. a fresh install creates the corrected step_timer_fires COMMENT -------
#
# The live column COMMENT was corrected on 2026-09-30, but a fresh install builds
# the table from migration 038, so 038 has to carry the same text or the false
# "control" claim comes back on every new database.

my $MIG = dirname($0) . '/../sql/migrate_038_move_census.sql';
open(my $mfh, '<', $MIG) or die "cannot read $MIG: $!";
my $migration = do { local $/; <$mfh> };
close($mfh);
$migration =~ s/\r//g;

my ($timer_comment) = ($migration =~ /^\s*step_timer_fires\s+INT UNSIGNED NOT NULL DEFAULT 0 COMMENT '([^']*)',\s*$/m);
ok(defined($timer_comment), '038 defines step_timer_fires as INT UNSIGNED NOT NULL DEFAULT 0 with a COMMENT');
is($timer_comment,
    'engine step-timer resets. NOT a control for steps_ground: it co-moves with duck actuation, so a ratio against it measures its own denominator rather than the steps',
    '038 creates the same step_timer_fires COMMENT the live correction set');
unlike($timer_comment // '', qr/CONTROL:|independent sensor/,
    '038 no longer calls step_timer_fires a control');
unlike($timer_comment // '', qr/;/,
    'the COMMENT carries no semicolon, which a statement splitter would cut on');
like($migration, qr/CREATE TABLE IF NOT EXISTS ktp_move_census\b/,
    '038 stays IF NOT EXISTS, so the COMMENT edit is a no-op on a database that has the table');

# --- 7. untracked windows are admitted, labelled, and kept apart ----------------
#
# Ruled 2026-11-02: an untracked window (matchid "-", half 0) is stored as match_id
# NULL / half 0 / producer_sequence NULL, because for play outside a tracked half this
# table is the only duck evidence there is. Three ways that goes wrong silently, each
# pinned below by RUNNING the shipped handler rather than reading it:
#   - a looser sentinel stores broken markers as "untracked" instead of dropping them;
#   - the daemon's receipt-time match context stamps warm-up as match time;
#   - the admission allocates manifest/sequence state, which the manifest gate bounds.
# ktpCaptureContextKey must still refuse half 0: every stream shares it, so widening
# it would have widened every gate at once.

{
    my $key_body = body_of('ktpCaptureContextKey');
    has($key_body, '$p->{matchid}',
        'control: ktpCaptureContextKey was extracted and reads matchid');
    has($key_body, '$p->{half} < 1',
        'ktpCaptureContextKey still refuses half 0 -- the admission is move-only, not a shared-key change');

    like($source, qr/my \$ktp_move_untracked = ktpIsUntrackedMoveCensus\(\\%ev_properties\);\s*if \(!\$ktp_move_untracked &&\s*!ktpCaptureManifestAuthorizes\(\\%ev_properties,\s*"move"\)\)/,
        'the move dispatch skips the manifest gate ONLY for the untracked sentinel');
    like($source, qr/doEvent_KTPMove\(\$ktp_buffered_player_id, \\%ev_properties,\s*\$ktp_move_untracked\)/,
        'and tells the handler which path it was admitted on');

    like($migration, qr/ktpIsUntrackedMoveCensus\b/,
        '038 names the admission point');
    like($migration, qr/match_id NULL, half 0 and producer_sequence NULL/,
        '038 states how an untracked row is stored');
    unlike($migration, qr/Those defaults are unreachable code/,
        '038 no longer says the untracked state is unreachable');
}

our (%g_servers, %g_ktpAcceptedCaptureManifests, %g_ktpCaptureSequences,
     %g_ktpMatchContext, $s_addr, @SQL, @WARN);

sub quoteSQL { my ($v) = @_; $v =~ s/\\/\\\\/g; $v =~ s/'/\\'/g; return $v; }
sub execNonQuery { push(@SQL, $_[0]); return 1; }
sub ktpWarnProducerClock { push(@WARN, join('|', @_)); }
# Proves a well-formed tracked clock the way the real resolver does; the resolver's
# own logic is tested elsewhere.
sub ktpResolveValidatedProducerEventContext {
    my ($m, $h, $gt, $ep) = @_;
    return (undef, undef, "invalid event_epoch", undef)
        if (!defined($ep) || $ep !~ /^[1-9]\d{0,18}$/);
    return (int($h), "dod_avalanche", "", "interval");
}

{
    my $lifted = '';
    for my $name (qw(ktpCaptureContextKey ktpHasExplicitProducerContext
                     ktpIsUntrackedMoveCensus doEvent_KTPMove)) {
        $lifted .= "sub $name {" . body_of($name) . "\n}\n";
    }
    eval "no strict 'vars';\n$lifted\n1;" or die "could not lift the move handler: $@";

    $s_addr = '127.0.0.1:27015';
    %g_servers = ($s_addr => { id => 7 });

    my %base = (window_ms => 30000, buckets => 2, bucket_width => 100, taps => 3,
        taps_ground => '1 2', taps_air => '0 0', ground_ms_standing => '100 0',
        ground_ms_ducked => '0 50', air_ms_ducked => '0 0', stam_tap_sum => 90,
        stam_tap_min => 30, steps_ground => 12, steps_ladder => 0, sounds_water => 0,
        pmove_sounds => 14, step_timer_fires => 20, map => 'dod_avalanche',
        matchid => 'KTP-1-abc', half => '1', game_time => '12.50',
        event_epoch => '1762900000', sequence => '9');
    my %untracked = (%base, matchid => '-', half => '0', sequence => '0');

    my $values = sub {
        my ($sql) = @_;
        my ($v) = (($sql // '') =~ /VALUES\s*\((.*)\)\s*$/s);
        return [ split(/,\s*/, $v // '') ];
    };
    my $run = sub {
        my ($p, $flag) = @_;
        @SQL = ();
        my $status = doEvent_KTPMove(4242, { %$p }, $flag);
        return ($status, $SQL[0]);
    };
    my $reset = sub {
        %g_ktpAcceptedCaptureManifests = (
            join("\x1e", $s_addr, 'KTP-1-abc', 1) => { schema => 26, move => 1 });
        %g_ktpCaptureSequences = ();
        %g_ktpMatchContext = ();
    };

    # The sentinel, exactly.
    ok(ktpIsUntrackedMoveCensus(\%untracked), 'the producer sentinel is recognised');
    ok(!ktpIsUntrackedMoveCensus({ %untracked, matchid => '' }),
        'an empty match id is NOT untracked -- it is broken');
    ok(!ktpIsUntrackedMoveCensus({ %untracked, half => '00' }), 'half "00" is not the sentinel');
    ok(!ktpIsUntrackedMoveCensus({ %untracked, half => '1' }),
        'a "-" match id with a real half is not the sentinel');
    ok(!ktpIsUntrackedMoveCensus({ %untracked, sequence => '5' }),
        'a non-zero sequence is not the sentinel -- an untracked line never takes a tracked sequence');
    ok(!ktpIsUntrackedMoveCensus({ %base }), 'control: a tracked marker is not untracked');
    my %no_seq = %untracked;
    delete $no_seq{sequence};
    ok(ktpIsUntrackedMoveCensus(\%no_seq), 'a sentinel with no sequence at all is still untracked');

    # Stored, labelled, and nothing allocated.
    $reset->();
    my %manifests_before = %g_ktpAcceptedCaptureManifests;
    my ($st, $sql) = $run->(\%untracked, 1);
    unlike($st // '', qr/dropped|failed/i, 'an untracked window is stored, not dropped');
    my $v = $values->($sql);
    is($v->[1], 'NULL', 'untracked: match_id is NULL');
    is($v->[2], '0', 'untracked: half is 0');
    is($v->[-2], 'NULL', 'untracked: producer_sequence is NULL');
    is($v->[-1], 'FROM_UNIXTIME(1762900000)', 'untracked: event_time comes from the producer epoch');
    is_deeply(\%g_ktpAcceptedCaptureManifests, \%manifests_before, 'untracked admission adds no manifest');
    is(scalar(keys %g_ktpCaptureSequences), 0, 'untracked admission allocates no sequence state');

    # Never stamped with the daemon's own view of the match.
    $reset->();
    %g_ktpMatchContext = ($s_addr => { match_id => 'KTP-1-abc', half_num => 1, round_live => 1 });
    ($st, $sql) = $run->(\%untracked, 1);
    $v = $values->($sql);
    is($v->[1], 'NULL', 'a live daemon match context does not stamp an untracked window');
    is($v->[2], '0', 'nor give it a half');

    # The one check that keeps an untracked event_time off FROM_UNIXTIME(0).
    for my $bad ('0', '', 'abc', undef) {
        $reset->();
        my %p = %untracked;
        if (defined($bad)) { $p{event_epoch} = $bad; } else { delete $p{event_epoch}; }
        ($st, $sql) = $run->(\%p, 1);
        my $label = defined($bad) ? "\"$bad\"" : 'absent';
        like($st // '', qr/dropped/, "untracked with event_epoch $label is dropped");
        ok(!defined($sql), "... and writes nothing ($label)");
    }

    # The flag alone is not enough: a non-sentinel marker takes the tracked path.
    $reset->();
    ($st, $sql) = $run->({ %base, matchid => 'KTP-unknown' }, 1);
    like($st // '', qr/no accepted manifest/,
        'the untracked flag on a non-sentinel marker does not bypass the manifest');

    # Tracked rows are unchanged.
    $reset->();
    ($st, $sql) = $run->(\%base, 0);
    unlike($st // '', qr/dropped|failed/i, 'control: a tracked window with a manifest is stored');
    $v = $values->($sql);
    is($v->[1], "'KTP-1-abc'", 'tracked: match_id is the producer match id');
    is($v->[2], '1', 'tracked: half is the validated half');
    is($v->[-2], '9', 'tracked: producer_sequence is kept');
    $reset->();
    %g_ktpAcceptedCaptureManifests = ();
    ($st, $sql) = $run->(\%base, 0);
    like($st // '', qr/no accepted manifest/, 'control: a tracked window without a manifest is still refused');
}

done_testing();
