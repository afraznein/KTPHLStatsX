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

has($source, 'position_sample|shot|move_census)$/) {',
    'move_census is in the capture-marker observation whitelist');
has($source, 'move_census => "move"',
    'move_census maps to the "move" sequence type');
has($source, '(?:life_boundary|team_membership|cap_break|break_context|position_sample|shot|move_census)$/',
    'move_census is in the buffered-identity whitelist');
like($source, qr/\}\s*elsif\s*\(\$ev_obj_a\s+eq\s+"move_census"\)\s*\{/,
    'move_census has a dispatch branch');
has($source, 'move => $capabilities{move} ? 1 : 0',
    'the accepted-manifest record carries the move capability bit');
has($source, '|team_membership|position|shot|move)$/);',
    'ktpCaptureManifestAuthorizes accepts "move" as an event type');
# Deliberately NOT an assertion that a new schema ordinal was accepted. This
# stream takes none: the capability bit is the gate, and the next ordinal is
# already promised to a different, ruled change. Assert the opposite instead --
# that nothing here quietly widened the manifest whitelist.
unlike($source, qr/int\(\$p->\{schema\}\) != 25/,
    'no schema ordinal was claimed for this stream; the capability bit gates it');

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

    # The RESERVED ceiling, not the geometry shipping today. Testing today's six
    # buckets would pass while the producer reserves room for more than the line can
    # hold -- which is exactly the state this started in. Mirrors
    # KSC_MOVE_MAX_BUCKETS in KTPAMXX plugins/dod/ktp_stats_capture.inc.
    my $BUCKETS = 8;
    my $big     = "999999";     # the producer's six-digit wire clamp
    # A width placeholder, not a SteamID. Only its LENGTH matters here, and a
    # real-looking one in a committed fixture is identity-shaped material in a
    # public repo for no test value at all. 95 chars is ksc_player_str's own cap
    # (raw[96]), not a typical name -- the worst case is the point.
    my $pstr    = ("x" x 59) . "<65535><STEAM_X:X:XXXXXXXXX><Allies>";
    my $matchid = "m" x 63;
    my $map     = "dod_" . ("m" x 27);
    my $hist    = join(" ", ($big) x $BUCKETS);

    my $worst = sprintf(
        '"%s" triggered "move_census" (window_ms "%s") (buckets "%d") (bucket_width "%d")'
      . ' (taps "%s") (taps_ground "%s") (taps_air "%s") (ground_ms_standing "%s")'
      . ' (ground_ms_ducked "%s") (air_ms_ducked "%s") (stam_tap_sum "%s") (stam_tap_min "%d")'
      . ' (steps_ground "%s") (steps_ladder "%s") (sounds_water "%s") (pmove_sounds "%s")'
      . ' (step_timer_fires "%s") (map "%s") (matchid "%s") (half "%d") (game_time "%.2f")'
      . ' (event_epoch "%d") (sequence "%d")',
        $pstr, $big, $BUCKETS, 50, $big,
        $hist, $hist, $hist, $hist, $hist,
        $big, 0, $big, $big, $big, $big, $big,
        $map, $matchid, 2, 99999.99, 2147483647, 9223372036854775807);

    diag("worst-case move_census line: " . length($worst) . " chars, budget " . ($KSC_BUF_LINE_LEN - 1));
    cmp_ok(length($worst), '<', $KSC_BUF_LINE_LEN - 1,
        'the worst-case line fits the producer buffer, terminator included');

    my @m = ($worst =~ $LINE_RE);
    ok(scalar(@m), 'the worst-case line matches the daemon dispatch regex');
    is($m[2], 'move_census', 'it dispatches as move_census');

    my %prop = getProperties($m[3]);
    for my $f (qw(window_ms buckets bucket_width taps taps_ground taps_air
                  ground_ms_standing ground_ms_ducked air_ms_ducked
                  stam_tap_sum stam_tap_min steps_ground steps_ladder
                  sounds_water pmove_sounds step_timer_fires map matchid
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

done_testing();
