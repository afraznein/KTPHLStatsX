#!/usr/bin/perl
# Focused regression for capture gap repair: a per-type sequence gap queues a
# coalesced rcon resend request, a resent marker closes the gap exactly once,
# a late original closes it too and then makes the resend redundant, and the
# health row reports gaps as UNREPAIRED gaps plus a repaired count.
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
my $observation = between_markers($source,
    '# BEGIN KTP CAPTURE SEQUENCE OBSERVATION',
    '# END KTP CAPTURE SEQUENCE OBSERVATION');

our (%g_servers, %g_ktpCaptureSequences, %g_ktpAcceptedCaptureManifests, $s_addr, %g_ktpResendLastSent,
     $g_ktpResendRedundant);
$s_addr = '10.0.0.5:27015';
my @rcon;
{
    package FakeServer;
    sub new { my ($c, %a) = @_; return bless {%a}, $c; }
    sub dorcon { my ($self, $cmd) = @_; push @rcon, $cmd; return ""; }
}
%g_servers = ($s_addr => FakeServer->new(id => 7, rcon_obj => 1));
sub printEvent { return 1; }

my $loaded = eval "no strict 'vars';\n$observation\n1;";
die "cannot load observation block: $@" unless $loaded;

# Seed accepted state the way a persisted manifest would.
my $key = join("\x1e", $s_addr, 'repair-TEST', 1);
$g_ktpAcceptedCaptureManifests{$key} = { schema => 24 };
$g_ktpCaptureSequences{$key} = { seq => {}, received => 0, types => {}, rejected => {},
    correlation_failures => {} };

sub observe { my ($type, $seq) = @_;
    ktpObserveCaptureMarker($type, { matchid => 'repair-TEST', half => 1, sequence => $seq }); }
my $slot = sub { $g_ktpCaptureSequences{$key}{seq}{position} };

observe('position', 1);
observe('position', 2);
observe('position', 5);                       # 3 and 4 lost in transit
is($slot->()->{gaps}, 2, 'a jump from 2 to 5 opens two gaps');
is_deeply([sort { $a <=> $b } keys %{$slot->()->{missing}}], [3, 4], 'both sequences are recorded as missing');

ktpFlushResendRequests();
is(scalar(@rcon), 1, 'one rcon per server per flush, not one per gap');
is($rcon[0], 'ktp_capture_resend position 3,4', 'request names the stream and the missing sequences, coalesced');
ktpFlushResendRequests();
is(scalar(@rcon), 1, 'nothing queued means no rcon');

# The resend for 3 arrives: gap closes, marker is data, not a duplicate.
observe('position', 3);
is($slot->()->{gaps}, 1, 'a resent sequence closes its gap');
is($slot->()->{repaired}, 1, 'and counts as repaired');
is($slot->()->{duplicate_or_reordered} || 0, 0, 'a repair is not a duplicate');
ok(!exists($slot->()->{missing}{3}), 'the sequence leaves the missing set');

# The late ORIGINAL 4 arrives before its resend: it repairs; the resend is then redundant.
observe('position', 4);
is($slot->()->{gaps}, 0, 'a late original closes the gap too');
my $resent_line = 'KTP_FLAG_STATE (map "dod_anzio") (flag_index "1") (matchid "repair-TEST") (half "1") (sequence "4") (resent "1")';
# flag_state, not position, so the marker classifier has to pick the stream from the line:
$g_ktpCaptureSequences{$key}{seq}{flag_state} = { first => 1, last => 5, gaps => 1, missing => { 4 => 1 } };
ok(!ktpResentLineIsRedundant($resent_line), 'a resent line whose sequence is still missing is admitted');
delete $g_ktpCaptureSequences{$key}{seq}{flag_state}{missing}{4};
ok(ktpResentLineIsRedundant($resent_line), 'once the gap is closed the same resend is redundant');
ok(!ktpResentLineIsRedundant('"Bob<3><STEAM_0:1:1><Axis>" triggered "damage" (matchid "repair-TEST") (half "1") (sequence "9")'),
    'a tagless line is never classified as resent');
ok(ktpResentLineIsRedundant('"Bob<3><STEAM_0:1:1><Axis>" triggered "damage" (matchid "repair-TEST") (half "1") (sequence "9") (resent "1")'),
    'a resent damage line with no open gap is redundant');

# A genuine duplicate (never missing) is still a duplicate.
observe('position', 5);
is($slot->()->{duplicate_or_reordered}, 1, 'an unrequested repeat is still a duplicate');

# Rate limit: a second flush within the interval sends nothing.
observe('position', 9);
ktpFlushResendRequests();
is(scalar(@rcon), 1, 'a flush inside the per-server interval is deferred');
$g_ktpResendLastSent{$s_addr} = 0;
ktpFlushResendRequests();
is($rcon[-1], 'ktp_capture_resend position 6,7,8', 'deferred request goes out on the next eligible flush');

# A hole wider than the cap is an outage, not loss: counted, never requested.
observe('position', 500);
is($slot->()->{gaps}, 493, 'a wide hole is counted as gaps (490 + the 3 still open)');
ok(!exists($slot->()->{missing}{10}), 'but not queued for resend');

done_testing();
