#!/usr/bin/perl
# A refused capture marker records WHY, not just that it was refused.
#
# Covers the normaliser (including the identity scrub), the per-stream tally and
# its distinct-reason ceiling, the health-row encoding, and a structural check
# that every rejection site in the daemon actually passes a reason -- the leg
# that catches the next stream being added without one.
use strict;
use warnings;
use Test::More;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';

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
$source =~ s/\r//g;
cmp_ok(length($source), '>', 100_000, 'daemon source loaded (not an empty read)');

my $observation = between_markers($source,
    '# BEGIN KTP CAPTURE SEQUENCE OBSERVATION',
    '# END KTP CAPTURE SEQUENCE OBSERVATION');

our (%g_servers, %g_ktpCaptureSequences, %g_ktpAcceptedCaptureManifests, $s_addr,
     %g_ktpResendLastSent, $g_ktpResendRedundant,
     $KTP_REJECT_REASON_MAX_DISTINCT, $KTP_REJECT_REASON_MAX_LEN);
$s_addr = '10.0.0.5:27015';
{
    package FakeServer;
    sub new { my ($c, %a) = @_; return bless {%a}, $c; }
    sub dorcon { return ""; }
}
%g_servers = ($s_addr => FakeServer->new(id => 7, rcon_obj => 1));
sub printEvent { return 1; }

# The tunables are declared above the main loop (a file-scope assignment below it
# never runs in daemon mode); read them from there so moving them back down here
# breaks this test as well as selftest-no-code-after-main-loop.pl.
my ($before_loop) = split /^while \(\$loop = &getLine\(\)\) \{/m, $source, 2;
my $tunables = join("\n",
    $before_loop =~ /^(our \$KTP_(?:RESEND|REJECT_REASON)_\w+\s*=\s*\d+;)/mg);
like($tunables, qr/KTP_REJECT_REASON_MAX_DISTINCT/,
    'the distinct-reason ceiling is assigned above the main loop');
like($tunables, qr/KTP_REJECT_REASON_MAX_LEN/,
    'the reason length cap is assigned above the main loop');

my $loaded = eval "no strict 'vars';\n$tunables\n$observation\n1;";
die "cannot load observation block: $@" unless $loaded;

# --- the normaliser -------------------------------------------------------
is(ktpNormalizeRejectReason(undef), 'unspecified',
    'a missing reason is named, not left empty');
is(ktpNormalizeRejectReason(''), 'unspecified', 'an empty reason is named too');
is(ktpNormalizeRejectReason('Shot dropped: no accepted schema-24+ manifest'),
    'Shot dropped: no accepted schema-24+ manifest',
    'an ordinary status string survives verbatim');
is(ktpNormalizeRejectReason("Move census\n dropped:   invalid  buckets"),
    'Move census dropped: invalid buckets',
    'whitespace collapses so one reason cannot become several');

# The identity scrub. These two are the only interpolating status strings in the
# daemon, and a verbatim reason would put per-player values in a health row.
is(ktpNormalizeRejectReason(
    "Position sample dropped for player=4211: unparseable position '1,2,3'"),
    'Position sample dropped: unparseable position',
    'an internal player id and the quoted payload are both scrubbed');
unlike(ktpNormalizeRejectReason("Shot dropped for player=99: bad 'STEAM_0:1:7' row"),
    qr/STEAM_|player=|99/, 'nothing identifying survives the scrub');
unlike(ktpNormalizeRejectReason('dropped: owner 76561198012345678 unresolved'),
    qr/7656/, 'a bare SteamID64 is scrubbed even unquoted');
is(length(ktpNormalizeRejectReason('x' x 500)), $KTP_REJECT_REASON_MAX_LEN,
    'one reason cannot exceed the length cap');

# --- the per-stream tally -------------------------------------------------
my $state = { reject_reasons => {} };
ktpNoteRejectReason($state, 'shot', 'Shot dropped: invalid weapon_id');
ktpNoteRejectReason($state, 'shot', 'Shot dropped: invalid weapon_id');
ktpNoteRejectReason($state, 'shot', 'Shot dropped: no accepted schema-24+ manifest');
ktpNoteRejectReason($state, 'move', 'Move census dropped: invalid buckets');
is($state->{reject_reasons}{shot}{'Shot dropped: invalid weapon_id'}, 2,
    'repeat reasons accumulate');
is($state->{reject_reasons}{shot}{'Shot dropped: no accepted schema-24+ manifest'}, 1,
    'a second reason for the same stream is kept apart');
is($state->{reject_reasons}{move}{'Move census dropped: invalid buckets'}, 1,
    'streams do not share a bucket');
is(scalar(keys %{$state->{reject_reasons}}), 2, 'and no third stream appeared');

my $flood = { reject_reasons => {} };
ktpNoteRejectReason($flood, 'shot', "reason $_") for (1 .. 40);
is(scalar(keys %{$flood->{reject_reasons}{shot}}),
    $KTP_REJECT_REASON_MAX_DISTINCT + 1,
    'past the ceiling the bucket stops growing (ceiling + the "other" slot)');
is($flood->{reject_reasons}{shot}{other},
    40 - $KTP_REJECT_REASON_MAX_DISTINCT,
    'and every folded rejection is still counted, under "other"');

# --- the health-row encoding ---------------------------------------------
is(ktpFormatRejectReasons(undef), undef, 'nothing rejected encodes as NULL');
is(ktpFormatRejectReasons({}), undef, 'an empty bucket encodes as NULL');
is(ktpFormatRejectReasons({ 'b' => 1, 'a' => 5, 'c' => 1 }), 'a=5;b=1;c=1',
    'most frequent first, name-ordered on a tie, so two identical halves match');
is(ktpFormatRejectReasons({ 'has=sign;and semi' => 2 }), 'hassignand semi=2',
    'the two separator characters are stripped rather than escaped');
my $wide = ktpFormatRejectReasons({ ('x' x 200) => 1, 'short' => 9 }, 40);
is($wide, 'short=9', 'a reason that would overflow the column budget is dropped, not cut');
cmp_ok(length(ktpFormatRejectReasons({ map { ('r' x 30) . $_ => 50 - $_ } 1 .. 12 })),
    '<=', 255, 'a full bucket still fits the column');

# --- a refused marker records its reason ---------------------------------
my $key = join("\x1e", $s_addr, 'reason-TEST', 1);
$g_ktpAcceptedCaptureManifests{$key} = { schema => 24, move => 0 };
$g_ktpCaptureSequences{$key} = { seq => {}, received => 0, types => {},
    rejected => {}, correlation_failures => {}, reject_reasons => {} };
my %props = (matchid => 'reason-TEST', half => 1, sequence => 1);

# The always-rejected case the capture-loss alert could page on but not explain:
# a stream the half's manifest does not authorize.
ktpRejectCaptureMarker('move', \%props, 0,
    'Move census dropped: manifest does not carry the move capability');
is($g_ktpCaptureSequences{$key}{rejected}{move}, 1, 'the rejection still counts');
is($g_ktpCaptureSequences{$key}{reject_reasons}{move}
    {'Move census dropped: manifest does not carry the move capability'}, 1,
    'and the reason a reader can act on is recorded beside it');
is(ktpFormatRejectReasons($g_ktpCaptureSequences{$key}{reject_reasons}{move}),
    'Move census dropped: manifest does not carry the move capability=1',
    'which is what the health row carries');

ktpRejectCaptureMarker('shot', \%props, 0, undef);
is($g_ktpCaptureSequences{$key}{reject_reasons}{shot}{unspecified}, 1,
    'a site that passes no reason is visible as unspecified, never as silence');

# --- every rejection site passes a reason --------------------------------
# Structural, because the cost of this defect is a stream added later whose
# rejections are mute again. Arity by paren-matching, not by regex: several
# calls span lines and one carries a ternary.
sub reject_call_arities {
    my ($text) = @_;
    my @arities;
    while ($text =~ /ktpReject(?:Unobserved)?CaptureMarker\(/g) {
        my $open = pos($text);
        next if (substr($text, 0, $open) =~ /sub \s*$/x);
        my ($i, $depth) = ($open, 1);
        while ($depth && $i < length($text)) {
            my $c = substr($text, $i, 1);
            $depth++ if ($c eq '(');
            $depth-- if ($c eq ')');
            $i++;
        }
        my $args = substr($text, $open, $i - 1 - $open);
        my ($top, $d) = (1, 0);
        for my $c (split //, $args) {
            $d++ if ($c eq '(' || $c eq '{');
            $d-- if ($c eq ')' || $c eq '}');
            $top++ if ($c eq ',' && $d == 0);
        }
        push @arities, $top;
    }
    return @arities;
}

my @arities = grep { defined } reject_call_arities($source);
cmp_ok(scalar(@arities), '>=', 30,
    'the structural check found the rejection sites (a zero here is a broken probe)');
my @mute = grep { $_ < 4 } @arities;
is(scalar(@mute), 0, 'every rejection site passes a reason');

# The control: the same check, against a call that does not. Without this a
# green "every site passes a reason" could mean the probe never fires.
my @control = reject_call_arities(
    'ktpRejectCaptureMarker("shot", \%p, $x ? 1 : 0);');
is_deeply(\@control, [3], 'and the check still reports a three-argument site');

done_testing();
