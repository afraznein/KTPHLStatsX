#!/usr/bin/perl
# An alarm must be audible at every DebugLevel.
#
# printEvent's gate is
#   (($g_debug > 0) && ($g_stdin == 0)) || (($g_stdin == 1) && ($force_output == 1))
# and the daemon reads UDP, so $g_stdin is always 0 and the second clause can
# never fire -- which makes force_output inert in production and leaves an
# alarm's audibility resting entirely on DebugLevel. Live config happens to
# carry DebugLevel 1, so the detectors work today by coincidence.
#
# This runs the SHIPPED printEvent from HLstats.plib against the SHIPPED
# printAlarm lifted out of hlstats.pl by marker -- a stub of either would
# test the stub. Every assertion is paired with the printEvent control that
# fails under the same conditions, so a green run means printAlarm is louder
# than printEvent rather than that nothing was measured.
use strict;
use warnings;
use Test::More;
use File::Spec;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';
# Absolute: `do` has not searched '.' since 5.26, and a bare relative path here
# fails in a way that reads as "the library defines nothing".
my $PLIB = File::Spec->rel2abs($SCRIPT_DIR . 'HLstats.plib');

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
my $alarm = between_markers($source,
    '# BEGIN KTP UNCONDITIONAL ALARM',
    '# END KTP UNCONDITIONAL ALARM');

# printEvent calls this; it lives in hlstats.pl, not the library.
sub is_number ($) { ( $_[0] ^ $_[0] ) eq '0' }

our ($g_debug, $g_stdin, $s_addr, $ev_timestamp);
$s_addr = '127.0.0.1:27015';
$ev_timestamp = '2026-09-04 00:00:00';

do $PLIB;
die "cannot load $PLIB: $@" if $@;
die "HLstats.plib did not define printEvent" unless defined(&printEvent);

my $loaded = eval "no strict 'vars';\n$alarm\n1;";
die "cannot load shipped printAlarm: $@" unless $loaded;
ok(defined(&printAlarm), 'hlstats.pl ships an unconditional alarm path');

# Capture what a call writes to stdout. Returns the line with its leading
# timestamp stripped, so two calls a second apart still compare equal.
sub emitted {
    my ($code_ref) = @_;
    my $buffer = '';
    open(my $capture, '>', \$buffer) or die "cannot open in-memory handle: $!";
    my $saved = select($capture);
    eval { $code_ref->(); 1 } or do { select($saved); die $@ };
    select($saved);
    close($capture);
    $buffer =~ s/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d: //;
    return $buffer;
}

my $desc = 'Stream x attempted 0 events while the half produced 9999 markers';

# --- the capture itself discriminates ---------------------------------------
# Every assertion below reads a captured buffer, so prove the capture reports
# output before believing it when it reports none.
{
    $g_debug = 1;
    $g_stdin = 0;
    my $control = emitted(sub { &printEvent('CONTROL', $desc, 1) });
    like($control, qr/\QCONTROL: $desc\E/,
        'stdout capture sees a line printEvent does emit');
}

# --- UDP mode, the way the daemon actually runs ------------------------------
{
    $g_stdin = 0;
    $g_debug = 0;

    my $gated = emitted(sub { &printEvent('KTP_TEST_ALARM', $desc, 1, 1) });
    is($gated, '',
        'printEvent is silent at DebugLevel 0 even with force_output set');

    my $loud = emitted(sub { &printAlarm('KTP_TEST_ALARM', $desc) });
    like($loud, qr/\QKTP_TEST_ALARM: $desc\E/,
        'printAlarm emits at DebugLevel 0');

    is($g_debug, 0, 'printAlarm restores the debug level it borrowed');
}

# --- --stdin mode, where the debug clause never applies ----------------------
{
    $g_stdin = 1;
    $g_debug = 0;

    my $loud = emitted(sub { &printAlarm('KTP_TEST_ALARM', $desc) });
    like($loud, qr/\QKTP_TEST_ALARM: $desc\E/,
        'printAlarm emits under --stdin at DebugLevel 0');
    $g_stdin = 0;
}

# --- format parity -----------------------------------------------------------
# Anything grepping these codes reads printEvent's line shape. Routing an alarm
# through printAlarm must not change a byte of it.
{
    $g_stdin = 0;
    $g_debug = 1;
    my $via_event = emitted(sub { &printEvent('KTP_TEST_ALARM', $desc, 1) });
    my $via_alarm = emitted(sub { &printAlarm('KTP_TEST_ALARM', $desc) });
    is($via_alarm, $via_event,
        'printAlarm reproduces printEvent line format exactly');
}

# --- the alarms that are actually routed through it --------------------------
# Naming them here is what keeps the set deliberate: a new printAlarm call site
# is a decision about what a quiet daemon still says, not a logging detail.
{
    my @expected = (
        'KTP_CAPTURE_STREAM_SILENT',
        'Unresolved action',
        'hlstats_Actions has NO rows',
    );
    for my $needle (@expected) {
        like($source, qr/printAlarm\(.{0,200}?\Q$needle\E/s,
            "'$needle' emits through the unconditional path");
    }

    # A quietened daemon must stay quiet outside those alarms. Per-event drop
    # reports keep printEvent deliberately; they are unbounded in volume.
    my ($health) = ($source =~ /sub doEvent_KTPCaptureHealth\s*\{(.*?)\n\}/s);
    unlike($health, qr/printEvent\(\s*"KTP_CAPTURE_STREAM_SILENT"/,
        'the silent-stream tripwire no longer uses the debug-gated path');

    my $alarm_calls = () = $source =~ /printAlarm\(/g;
    is($alarm_calls, 3,
        'the alarm set is exactly the three bounded, data-loss conditions');
}

done_testing();
