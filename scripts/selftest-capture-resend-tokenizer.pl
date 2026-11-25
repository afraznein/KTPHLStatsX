#!/usr/bin/perl
# The resend request has to survive the trip the game server gives it: the rcon
# packet is cut by SV_Rcon, tokenized by Cmd_TokenizeString/COM_Parse, and read by
# the producer's ksc_cmd_resend with read_argv(2). COM_Parse makes ',' a token of
# its own, so an unquoted "3,4,5" reaches the handler as "3" and every sequence
# after the first is never resent. selftest-capture-gap-repair.pl uses a fake rcon
# and cannot see that; this one runs the daemon's real request through replicas of
# the engine tokenizer and the handler.
#
# Replicas of, on origin/main:
#   KTP-ReHLDS rehlds/engine/common.cpp  COM_Parse
#   KTP-ReHLDS rehlds/engine/cmd.cpp     Cmd_TokenizeString
#   KTP-ReHLDS rehlds/engine/sv_main.cpp SV_Rcon (rcon_buff[512], skips 3 tokens)
#   KTPAMXX    plugins/dod/ktp_stats_capture.inc ksc_cmd_resend + strtok_seq
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

# --- engine replicas ------------------------------------------------------

my $BREAK = qr/[{}()',:]/;   # com_ignorecolons is 0 on a dedicated server

# Returns (token, rest) or () at end of input.
sub com_parse {
    my ($data) = @_;
    while (1) {
        $data =~ s/^[\x00-\x20]+//;
        return () if ($data eq '');
        if ($data =~ s{^//[^\n]*}{}) { next; }
        last;
    }
    if ($data =~ s/^"//) {
        my $at = index($data, '"');
        return ($data, '') if ($at < 0);
        return (substr($data, 0, $at), substr($data, $at + 1));
    }
    if ($data =~ s/^($BREAK)//) { return ($1, $data); }
    $data =~ s/^((?:(?!$BREAK)[^\x00-\x20])+)// or die "unreachable";
    return ($1, $data);
}

sub cmd_tokenize {
    my ($text) = @_;
    my @argv;
    while (1) {
        $text =~ s/^[\x00-\x09\x0b-\x20]+//;
        last if ($text eq '' || substr($text, 0, 1) eq "\n");
        my ($token, $rest) = com_parse($text);
        last if (!defined($token));
        last if (length($token) + 1 >= 516);
        push @argv, $token;
        $text = $rest;
        last if (@argv >= 80);
    }
    return @argv;
}

# SV_Rcon copies the datagram past its first 4 bytes (the 0xFF header) into
# rcon_buff[512], parses off "rcon", the challenge and the password, and executes
# the remainder. Returns argv, or undef when the engine would drop the packet.
sub sv_rcon_argv {
    my ($password, $command) = @_;
    my $datagram = "\xFF\xFF\xFF\xFFrcon 1234567890 \"$password\" $command\0";   # BASTARDrcon's layout
    return undef if (length($datagram) - 4 >= 512);
    my $rest = "rcon 1234567890 \"$password\" $command";
    for (1 .. 3) { (undef, $rest) = com_parse($rest); }
    return [cmd_tokenize($rest)];
}

# --- producer replica: ksc_cmd_resend ------------------------------------

# Returns the sequences the handler would look up, in order.
sub ksc_cmd_resend {
    my ($argv) = @_;
    my $seqs = defined($argv->[2]) ? substr($argv->[2], 0, 255) : '';   # seqs[256]
    my @wanted;
    my $pos = 0;
    while ($pos < length($seqs)) {
        my $src = substr($seqs, $pos);
        my $i = 0;
        my $token = '';
        while ($i < length($src) && substr($src, $i, 1) ne ',' && $i < 15) {   # token[16]
            $token .= substr($src, $i, 1);
            $i++;
        }
        $pos += ($i < length($src) && substr($src, $i, 1) eq ',') ? $i + 1 : $i;
        my ($num) = $token =~ /^\s*(-?\d+)/;
        next if (!defined($num) || $num <= 0);
        push @wanted, $num;
    }
    return @wanted;
}

# --- drive the daemon's real request path --------------------------------

my $source = slurp($SRC);
$source =~ s/\r//g;
my $observation = between_markers($source,
    '# BEGIN KTP CAPTURE SEQUENCE OBSERVATION',
    '# END KTP CAPTURE SEQUENCE OBSERVATION');

our (%g_servers, %g_ktpCaptureSequences, %g_ktpAcceptedCaptureManifests, $s_addr, %g_ktpResendLastSent,
     $g_ktpResendRedundant, $KTP_RESEND_MAX_PER_CMD, %g_ktpResendQueue);
$s_addr = '10.0.0.5:27015';
my @rcon;
{
    package FakeServer;
    sub new { my ($c, %a) = @_; return bless {%a}, $c; }
    sub dorcon { my ($self, $cmd) = @_; push @rcon, $cmd; return ""; }
}
%g_servers = ($s_addr => FakeServer->new(id => 7, rcon_obj => 1));
sub printEvent { return 1; }

my ($before_loop) = split /^while \(\$loop = &getLine\(\)\) \{/m, $source, 2;
my $tunables = join("\n", $before_loop =~ /^(our \$KTP_RESEND_\w+\s*=\s*\d+;)/mg);
my $loaded = eval "no strict 'vars';\n$tunables\n$observation\n1;";
die "cannot load observation block: $@" unless $loaded;

my $key = join("\x1e", $s_addr, 'tok-TEST', 2);
$g_ktpAcceptedCaptureManifests{$key} = { schema => 24 };
$g_ktpCaptureSequences{$key} = { seq => {}, received => 0, types => {}, rejected => {},
    correlation_failures => {} };
sub observe { my ($type, $seq) = @_;
    ktpObserveCaptureMarker($type, { matchid => 'tok-TEST', half => 2, sequence => $seq }); }
sub reset_requests { %g_ktpResendQueue = (); $g_ktpResendLastSent{$s_addr} = 0; @rcon = (); }

# The 2026-11-24 ATL1 h2 burst: damage 191 arrived, 192..196 were lost.
observe('damage', $_) for (1 .. 191);
observe('damage', 197);
ktpFlushResendRequests();
is(scalar(@rcon), 1, 'one request for the burst');
my $argv = sv_rcon_argv('x' x 32, $rcon[0]);
ok($argv, 'the request fits the engine rcon buffer');
is($argv->[0], 'ktp_capture_resend', 'command name survives tokenizing');
is($argv->[1], 'damage', 'stream survives tokenizing');
is_deeply([ksc_cmd_resend($argv)], [192 .. 196], 'the handler sees all 5 of 5 missing sequences');

# The pre-fix form, through the same replicas, recovers only the first.
my $old = sv_rcon_argv('x' x 32, 'ktp_capture_resend damage 192,193,194,195,196');
is_deeply([ksc_cmd_resend($old)], [192], 'control: the unquoted list reaches the handler as 1 of 5');

# A full batch at the per-command cap, with sequence numbers far past any half
# measured, on the longest stream name: every sequence still reaches the handler.
reset_requests();
my $base = 900000;
observe('objective_attempt', $base);
observe('objective_attempt', $base + $KTP_RESEND_MAX_PER_CMD + 1);
ktpFlushResendRequests();
is(scalar(@rcon), 1, 'a cap-sized gap is one request');
$argv = sv_rcon_argv('x' x 32, $rcon[0]);
ok($argv, 'a cap-sized request with six-digit sequences fits the rcon buffer');
is_deeply([ksc_cmd_resend($argv)], [($base + 1) .. ($base + $KTP_RESEND_MAX_PER_CMD)],
    "the handler sees $KTP_RESEND_MAX_PER_CMD of $KTP_RESEND_MAX_PER_CMD at the cap");
ok(length($argv->[2]) <= 255, 'the list fits the handler\'s seqs[256] buffer');

# Over the cap, the remainder goes out on the next flush and is also whole.
reset_requests();
observe('position', $_) for (1 .. 10);
observe('position', 10 + $KTP_RESEND_MAX_PER_CMD + 6);   # cap + 5 missing
ktpFlushResendRequests();
$g_ktpResendLastSent{$s_addr} = 0;
ktpFlushResendRequests();
is(scalar(@rcon), 2, 'cap + 5 missing goes out as two requests');
my @got = map { ksc_cmd_resend(sv_rcon_argv('x' x 32, $_)) } @rcon;
is_deeply(\@got, [11 .. (10 + $KTP_RESEND_MAX_PER_CMD + 5)], 'every missing sequence reaches the handler across both');

# Replica sanity, so a broken replica cannot pass the tests above by accident.
is_deeply([cmd_tokenize('a 1,2 "3,4"')], ['a', '1', ',', '2', '3,4'], 'replica: comma is its own token, quotes hold one');

done_testing();
