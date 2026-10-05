#!/usr/bin/perl
#
# The aim-vis stream has to be named in the same nine hand-maintained places in
# hlstats.pl that selftest-move-census.pl enumerates for `move`. That file exists
# because `shot` was added to four of them and missed in the capture-health
# allow-list, which would have left a whole stream with no drop detection and
# nothing would have failed. This is the same test for this stream.
#
# It also pins the two contracts this stream cannot be allowed to lose, because
# both are silent when broken and both have a tempting wrong form:
#   - the DENOMINATOR travels in the same row as the numerator, and
#   - "packed" is never stored or derived as if it meant "visible".
#
# It asserts on the shipped hlstats.pl text rather than running the daemon, the
# same way selftest-move-census.pl and selftest-position-batching.pl do. A stream
# can be wired correctly and still be wrong, but it cannot be wired incorrectly
# and be right.
#
# Exact-text checks use index() with single-quoted needles on purpose: the
# strings being matched are full of $sigils, and a qr// would interpolate them
# into nothing and then pass against anything.

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
# that never appears. Anchor on something that must already be there, and on
# something that must not be, so the harness is shown to discriminate.
has($source, 'sub doEvent_KTPMove', 'control: a known-present literal is found');
hasnt($source, 'sub doEvent_KTPZzzNoSuchHandler', 'control: an absent literal is not found');

# --- 1. the nine registration points ---------------------------------------

# The three whitelists are asserted as MEMBERSHIP in the alternation, never as a
# remembered tail of it. Pinning the tail is what broke all three of the sibling
# move-census assertions the moment this stream was added: a brittle needle on a
# shared list reports one stream as unregistered because a different one arrived.
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
    registered_in(\@obs, 'aim_vis',
        'aim_vis is in the capture-marker observation whitelist');
}
has($source, 'aim_vis => "aim_vis"',
    'aim_vis maps to the "aim_vis" sequence type');
{
    my @buf = ($source =~ /\$ev_obj_a =~ \/\^\(\?:([^)]*)\)\$\//g);
    registered_in(\@buf, 'aim_vis',
        'aim_vis is in the buffered-identity whitelist');
}
like($source, qr/\}\s*elsif\s*\(\$ev_obj_a\s+eq\s+"aim_vis"\)\s*\{/,
    'aim_vis has a dispatch branch');
has($source, 'aim_vis => $capabilities{aim_vis} ? 1 : 0',
    'the accepted-manifest record carries the aim_vis capability bit');
{
    my $auth = body_of('ktpCaptureManifestAuthorizes');
    my ($types) = (($auth // '') =~ /\$event_type !~ \/\^\(\?:([^)]*)\)\$\//);
    registered_in([defined($types) ? $types : ()], 'aim_vis',
        'ktpCaptureManifestAuthorizes accepts "aim_vis" as an event type');
}

# Deliberately NOT an assertion that a new schema ordinal was accepted. This
# stream takes none: the capability bit is the gate, exactly as for `move`. Pin
# the whitelist to the ruled set -- anything widening it has to name the ruled
# change that owns the ordinal, and this stream is not it.
{
    my $validator = body_of('ktpValidateCaptureManifestPayload');
    my ($clause) = (($validator // '') =~ /return "unsupported schema"(.*?);/s);
    my @ordinals = sort { $a <=> $b } (($clause // '') =~ /!= (\d+)/g);
    is(join(',', @ordinals), '21,22,23,24,25,26',
        'no schema ordinal was claimed for this stream; the capability bit gates it');
}

{
    my $resend = body_of('ktpResentLineIsRedundant');
    has($resend, 'aim_vis => "aim_vis"',
        'resent aim_vis lines are recognised (or every resend of one is dropped)');
}

{
    # The one that was missed for `shot`.
    my ($allowed) = ($source =~ /my %allowed = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    ok(defined($allowed), 'the capture-health allow-list was found');
    like($allowed // '', qr/\baim_vis\b/,
        'the capture-health allow-list names "aim_vis" -- the exact line `shot` was missed on');
}

{
    # The SAME class of miss, four lines further down, and the allow-list
    # assertion above does not catch it: a stream named in neither %always_active
    # nor %manifest_gated falls through the elsif and returns "" unconditionally,
    # so it can go dark forever with no warning.
    my ($gated) = ($source =~ /my %manifest_gated = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    my ($always) = ($source =~ /my %always_active = map \{ \$_ => 1 \} qw\(([^)]*)\)/);
    ok(defined($gated) && defined($always), 'the silent-stream classification sets were found');
    like($gated // '', qr/\baim_vis\b/,
        '"aim_vis" is in the MANIFEST-GATED set: the bit is what separates "not authorised" from "authorised and silent"');
}

# --- 2. the handler's own contracts ----------------------------------------

my $body = body_of('doEvent_KTPAimVis');
ok(defined($body), 'doEvent_KTPAimVis exists');

# About a third of the assertions below are NEGATIVE: nothing thresholds,
# nothing derives a packed count, nothing computes a rate. A negative assertion
# against a MISSING body passes, which would report a clean measure-only
# contract for a handler that does not exist -- an assert that cannot fail.
# Route every negative through here so an absent body fails them instead.
sub body_unlike {
    my ($re, $name) = @_;
    if (!defined($body)) {
        fail($name);
        diag('doEvent_KTPAimVis is absent, so this negative cannot be measured');
        return;
    }
    unlike($body, $re, $name);
}

{
    my ($success) = ($body =~ /return\s+("Aim vis logged[^"]*")/);
    ok(defined($success), 'the handler has a success return string');
    unlike($success // '', qr/dropped|failed/i,
        'the success string does not trip the call site /dropped|failed/i reject');
    like($source, qr/ktpRejectCaptureMarker\("aim_vis".{0,200}?dropped\|failed/s,
        'the call site rejects on the same classifier the handler avoids');
}

has($body, '$manifest->{schema} < 23 || !$manifest->{aim_vis}',
    'the handler refuses a manifest that does not authorise this stream');

# \b after the table name, not a bare substring: without it this passes against
# ktp_aim_vis_anything, which is a different table.
like($body, qr/INSERT\s+IGNORE\s+INTO\s+ktp_aim_vis\b/,
    'the handler writes ktp_aim_vis with the INSERT IGNORE dedup contract');

has($body, 'Aim vis dropped: invalid game_time',
    'game_time is regex-guarded rather than left to Perl numification');

# --- 3. the denominator contract -------------------------------------------
#
# samples_unpacked without samples_known beside it is not interpretable, and the
# cheapest way to lose that is for a missing counter to default to 0: a malformed
# denominator then reads as "this player took no samples" rather than as a
# malformed marker. Every other ktp_* stream defaults its counters to 0, which is
# correct there and wrong here, so assert the difference explicitly.

{
    my ($required) = ($body =~ /for my \$field \(qw\(([^)]*)\)\)/);
    ok(defined($required), 'the handler has a required-counter list');
    for my $f (qw(samples_known samples_unpacked samples_unknown)) {
        like($required // '', qr/\b\Q$f\E\b/,
            "$f is in the required-counter list, so a missing one is dropped");
    }
    has($body, 'return "Aim vis dropped: invalid $field"',
        'a missing or non-numeric counter returns a drop, not a default');
    # The positive form of the same rule. move_census and shot both funnel their
    # counters through a $counter-> sub that returns 0 for anything unparseable,
    # which is correct there and would destroy the denominator here.
    hasnt($body, '$counter',
        'no $counter-> default anywhere in this handler -- a 0 denominator is not a measurement');
}
has($body, 'Aim vis dropped: samples_unpacked exceeds samples_known',
    'the subset invariant is enforced at the door, where it can be blamed on the producer');

{
    my @inserts = ($body =~ /INSERT\s+IGNORE\s+INTO\s+ktp_aim_vis\b/g);
    is(scalar(@inserts), 1,
        'the census is written as ONE row -- splitting numerator from denominator makes the uninterpretable read easy');
    for my $col (qw(samples_known samples_unpacked samples_unknown recorder_live)) {
        has($body, $col, "the single INSERT carries $col");
    }
}

# --- 4. "packed" is never stored, and never derived --------------------------
#
# PVS is leaf-based and generous: an entity is routinely packed while standing
# behind a wall. A column or expression that reads "packed" as "legitimately
# seen" has stopped measuring behaviour and started measuring level geometry.

body_unlike(qr/samples_packed/,
    'the handler stores no samples_packed -- the packed direction supports nothing');
body_unlike(qr/samples_known\}?\s*-\s*\$?\w*samples_unpacked/,
    'nothing derives a packed count by subtraction inside the handler');

# --- 5. the measure-only contract ------------------------------------------
#
# There is no cut point for this stream, and the consumer that would hold one is
# private. Assert that none appeared here, and that no rate is computed at all --
# a fraction stored in this row would make the denominator rule unenforceable
# downstream.

body_unlike(qr/(?:samples_unpacked|samples_known|samples_unknown)\}?\s*[<>]=?\s*\d/,
    'the handler compares no counter against a threshold');
body_unlike(qr/\bsuspicious\b|\bverdict\b|\bcheat\b|\bwallhack\b/i,
    'the handler reaches no conclusion about a player');
body_unlike(qr/\$\w*samples_unpacked\w*\s*\/\s*\$/,
    'the handler computes no rate -- the rate is the consumer job, with both columns in hand');

# --- 6. the window columns are the LOOKBACK, not the flush interval ----------
#
# ktp_move_census already has a column literally called window_ms that IS the
# flush interval. Two tables, same word, different quantities. The only thing
# keeping them apart is that this stream calls its interval interval_ms, so the
# handler must not reintroduce the collision.

has($body, 'interval_ms',
    'the flush interval is carried as interval_ms, not as window_ms');
has($body, 'Aim vis dropped: window exceeds the interval that produced it',
    'a per-sample lookback wider than the interval it was sampled in is rejected');
has($body, 'Aim vis dropped: window reported with no answered samples',
    'a window total with samples_known 0 is rejected -- the native cannot produce one');

# --- 7. the wire format actually parses -------------------------------------
#
# Everything above checks that the stream is WIRED UP. This checks that the line
# the producer will emit can be READ, using the daemon's own getProperties rather
# than a reimplementation of it -- a copy would pass while the real parser choked.
# It also measures the worst-case width, because the producer's buffer truncates
# silently and a truncated line stops matching the dispatch regex without failing
# anywhere. That is how the life-boundary stream lost its sequence field.

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

    my $big = "4294967295";      # an INT UNSIGNED column at full width
    my $sum = "18446744073709551615";
    # A width placeholder, not a SteamID. Only its LENGTH matters here, and a
    # real-looking one in a committed fixture is identity-shaped material in a
    # public repo for no test value at all. ksc_player_str caps at raw[96].
    my $pstr    = ("x" x 59) . "<65535><STEAM_X:X:XXXXXXXXX><Allies>";
    my $matchid = "m" x 63;
    my $map     = "dod_" . ("m" x 27);

    my $worst = sprintf(
        '"%s" triggered "aim_vis" (interval_ms "%s") (samples_known "%s")'
      . ' (samples_unpacked "%s") (samples_unknown "%s") (window_ms_sum "%s")'
      . ' (window_ms_max "%s") (recorder_live "%d") (map "%s") (matchid "%s")'
      . ' (half "%d") (game_time "%.2f") (event_epoch "%d") (sequence "%d")',
        $pstr, $big, $big, $big, $big, $sum, $big, 1,
        $map, $matchid, 2, 99999.99, 2147483647, 9223372036854775807);

    diag("worst-case aim_vis line: " . length($worst) . " chars, budget " . ($KSC_BUF_LINE_LEN - 1));
    cmp_ok(length($worst), '<', $KSC_BUF_LINE_LEN - 1,
        'the worst-case line fits the producer buffer, terminator included');

    my @m = ($worst =~ $LINE_RE);
    ok(scalar(@m), 'the worst-case line matches the daemon dispatch regex');
    is($m[2], 'aim_vis', 'it dispatches as aim_vis');

    my %prop = getProperties($m[3]);
    for my $f (qw(interval_ms samples_known samples_unpacked samples_unknown
                  window_ms_sum window_ms_max recorder_live map matchid half
                  game_time event_epoch sequence)) {
        ok(defined($prop{$f}), "the handler field '$f' survives getProperties");
    }
    is($prop{map}, $map, 'map survives at full column width');
    is($prop{matchid}, $matchid, 'matchid survives at full column width');

    # getProperties drops an EMPTY quoted value, which is correct and is also the
    # trap: a legitimate zero must not be what disappears. Zero is the ordinary
    # reading for every counter in this stream, and for recorder_live it is the
    # reading that says the instrument was off.
    my %zero = getProperties('(samples_unpacked "0") (samples_known "0") (recorder_live "0")');
    is($zero{samples_unpacked}, "0", 'a zero numerator is a value, not an absence');
    is($zero{samples_known}, "0", 'a zero denominator is a value, not an absence');
    is($zero{recorder_live}, "0", 'recorder_live 0 is a value -- it says the instrument was off');
}

# --- 8. the migration a fresh install builds the table from ------------------

{
    my $MIG = dirname($0) . '/../sql/migrate_042_aim_vis.sql';
    open(my $mfh, '<', $MIG) or die "cannot read $MIG: $!";
    my $migration = do { local $/; <$mfh> };
    close($mfh);
    $migration =~ s/\r//g;

    my ($first_line) = split(/\n/, $migration);
    like($first_line, qr/^-- ENGINE: mysql\b/,
        'line 1 declares the engine -- this queue serves two databases and nothing else distinguishes them');
    like($migration, qr/CREATE TABLE IF NOT EXISTS ktp_aim_vis\b/,
        'the table is created IF NOT EXISTS, so a comment correction is a no-op on a database that has it');

    # Tracked-only, stated in the schema rather than in a reader head. The
    # sibling ktp_move_census advertises a nullable match_id and a half of 0 that
    # its producer cannot emit, and the next reader believes that data exists.
    like($migration, qr/^\s*match_id VARCHAR\(64\) NOT NULL\b/m,
        'match_id is NOT NULL -- no state is advertised that the producer cannot reach');
    like($migration, qr/^\s*half TINYINT NOT NULL\b/m,
        'half is NOT NULL');
    unlike($migration, qr/half[^\n]*0=no match context/,
        'half carries no no-match-context sentinel');

    # Asserted on the comment-stripped text: this file NAMES samples_packed in
    # its header and in a VERIFY query that proves the column is absent, so the
    # same check against the raw file fails on its own documentation.
    my $ddl = join("\n", grep { !/^\s*--/ } split(/\n/, $migration));
    unlike($ddl, qr/\bsamples_packed\b/,
        'there is no samples_packed column -- the packed direction supports nothing');
    like($migration, qr/\bsamples_known\b/, 'the denominator column exists');
    like($migration, qr/\bsamples_unpacked\b/, 'the numerator column exists');
    like($migration, qr/\bsamples_unknown\b/, 'the third state has its own column');

    # One statement. A semicolon inside a quoted COMMENT is cut by a naive
    # splitter, and the half that lands parses -- which is how this fails
    # silently rather than loudly. 038 carries exactly that defect in its
    # window_ms COMMENT, so it is not hypothetical.
    my $code = join("\n", grep { !/^\s*--/ } split(/\n/, $migration));
    my @comments = ($code =~ /COMMENT '([^']*)'/g);
    cmp_ok(scalar(@comments), '>', 0, 'the table carries column COMMENTs');
    is(scalar(grep { /;/ } @comments), 0,
        'no COMMENT carries a semicolon, which a statement splitter would cut on');
    is(scalar(() = $code =~ /;/g), 1,
        'the migration is exactly one statement');

    # The whole point of the file, in the file. A later editor who deletes this
    # has to delete a failing test with it.
    like($migration, qr/MEASURE-ONLY/,
        'the table comment says measure-only');
    unlike($code, qr/\bCHECK\s*\(/,
        'no CHECK constraint -- the MySQL version is pinned nowhere in this repo and a silently-ignored CHECK reads like a guarantee');
}

done_testing();
