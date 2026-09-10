#!/usr/bin/perl
# Batched ktp_position_samples: the couplings that fail silently.
#
# Batching position INSERTs removes the UDP-intake stall measured in
# SEQUENCE_GAP_ROOT_CAUSE_UDP_INTAKE_LOSS_20260910.md (emitted-minus-received
# == sequence_gap_count in 13 of 13 halves; drops=2356 on the daemon's own
# socket). What it introduces is a set of couplings that are invisible at
# runtime until data is already gone:
#
#   1. The call site classifies doEvent_KTPPosition's RETURN STRING with
#      /dropped|failed/i and rejects the marker when it matches. A queued row
#      that says "logged" is a lie; one that says "failed" rejects every
#      sample. The word choice is load-bearing.
#   2. A queue only drains if something drains it. The size threshold alone
#      leaves a partial batch pending at half end (health) and at shutdown
#      (flushAll) -- and those rows were already counted daemon_received, so
#      losing them reads later as an unexplained health mismatch, not an error.
#   3. A flush that does not clear its queue double-inserts every row.
#
# Source-level assertions, in the style of selftest-alarm-audibility.pl: these
# are properties of how the shipped code is wired, and a stubbed harness would
# test the stub rather than the wiring.
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
    my $content = <$fh>;
    close($fh);
    return $content;
}

my $source = slurp($SRC);

sub body_of {
    my ($name) = @_;
    my ($body) = ($source =~ /sub \Q$name\E\s*\{(.*?)\n\}/s);
    die "could not extract sub $name" if (!defined($body));
    return $body;
}

# --- 1. the return-string contract with the call site ----------------------
{
    my $body = body_of('doEvent_KTPPosition');
    my ($success) = ($body =~ /return\s+("Position sample queued[^"]*")/);
    ok(defined($success), 'doEvent_KTPPosition has a queued-path return string');
    unlike($success // '', qr/dropped|failed/i,
        'the queued return string does not trip the call site /dropped|failed/i reject');

    # And the classifier it must not trip is still the one we think it is.
    like($source, qr/ktpRejectCaptureMarker\("position".{0,200}?dropped\|failed/s,
        'the position call site still classifies on /dropped|failed/i');
}

# --- 2. every drain path -------------------------------------------------
{
    my $calls = () = $source =~ /flushPositionEvents\(\)/g;
    # threshold + health marker + shutdown, plus the sub's own definition line
    # is not a call, so: push-site, health, flushAll.
    cmp_ok($calls, '>=', 3,
        'flushPositionEvents is called from the threshold, health, and shutdown paths');

    my $pos = body_of('doEvent_KTPPosition');
    like($pos, qr/flushPositionEvents\(\)\s+if\s+\(scalar\(\@g_ktpPositionQueue\)\s*>=\s*\$g_ktp_position_queue_size\)/,
        'the size threshold drains the queue');

    # Window from the health marker forward, rather than brace-matching a
    # branch of a 600-line if/elsif chain with a regex.
    my $idx = index($source, 'ktpObserveCaptureMarker("health"');
    ok($idx >= 0, 'the health marker branch is present');
    my $health_block = substr($source, $idx, 600);
    like($health_block, qr/flushPositionEvents\(\)/,
        'the half-boundary health marker drains a partial batch');

    my $flushall = body_of('flushAll');
    like($flushall, qr/flushPositionEvents\(\)/,
        'shutdown drains a partial batch before exit');
    # The shot queue shipped without this and would lose its partial batch on
    # SIGINT; fixed alongside, so guard it too.
    like($flushall, qr/flushShotEvents\(\)/,
        'shutdown also drains the shot batch');
}

# --- 3. a flush clears its queue -----------------------------------------
{
    my $flush = body_of('flushPositionEvents');
    like($flush, qr/\@g_ktpPositionQueue\s*=\s*\(\)/,
        'flushPositionEvents clears the queue (or every row inserts twice)');
    like($flush, qr/return\s+if\s+\(scalar\(\@g_ktpPositionQueue\)\s*==\s*0\)/,
        'an empty flush is a no-op rather than an empty INSERT');
    like($flush, qr/INSERT INTO ktp_position_samples/,
        'flushPositionEvents targets ktp_position_samples');
    like($flush, qr/join\(",\\n\\t\\t\\t", \@g_ktpPositionQueue\)/,
        'rows are joined into one multi-row INSERT rather than one INSERT each');

    # The queued row must be a parenthesised VALUES tuple; an arity mismatch
    # against the column list is a runtime SQL error on the first flush, which
    # Lane B surfaces immediately, so this only guards the shape.
    my $pos = body_of('doEvent_KTPPosition');
    like($pos, qr/push\(\@g_ktpPositionQueue, \$value\)/,
        'the built tuple is what gets queued');
    like($pos, qr/my \$value = "\(/,
        'the queued row opens as a VALUES tuple');
}

done_testing();
