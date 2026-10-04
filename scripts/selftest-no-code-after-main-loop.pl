#!/usr/bin/perl
# The daemon's main loop never exits in UDP mode, so file-scope assignments
# placed after it never run. This pins config above the loop and fails on any
# assignment that drifts below it.
use strict;
use warnings;
use Test::More;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';

open(my $fh, '<', $SRC) or die "cannot read $SRC: $!";
my @lines = map { s/\r?\n\z//r } <$fh>;
close($fh);

my ($loop_start) = grep { $lines[$_] =~ /^while \(\$loop = &getLine\(\)\) \{/ } 0 .. $#lines;
ok(defined $loop_start, 'main loop found');
my $loop_end;
if (defined $loop_start) {
    ($loop_end) = grep { $_ > $loop_start && $lines[$_] =~ /^\}/ } 0 .. $#lines;
}
ok(defined $loop_end, 'main loop closing brace found');

my @stray;
if (defined $loop_end) {
    my $in_sub = 0;
    for my $i ($loop_end + 1 .. $#lines) {
        my $l = $lines[$i];
        if ($l =~ /^sub\s/) { $in_sub = 1; next; }
        if ($in_sub) { $in_sub = 0 if $l =~ /^\}/; next; }
        next unless $l =~ /^(?:(?:our|my|local)\s+)?[\$\@\%][\w:]+(?:\{[^}]*\}|\[[^\]]*\])?\s*=(?![=~])/;
        next if $l =~ /^\$end_time\s*=/;    # stdin-import epilogue, reached when the loop ends
        push @stray, sprintf('line %d: %s', $i + 1, $l);
    }
}
is(scalar(@stray), 0, 'no file-scope assignment after the main loop') or diag(join("\n", @stray));

my %expect = (
    KTP_RESEND_MAX_PER_GAP   => 256,
    KTP_RESEND_MAX_MISSING   => 256,
    KTP_RESEND_MAX_PER_CMD   => 32,
    KTP_RESEND_MIN_INTERVAL  => 2,
);
my %seen;
if (defined $loop_start) {
    for my $i (0 .. $loop_start - 1) {
        $seen{$1} = $2 if $lines[$i] =~ /^our \$(KTP_RESEND_\w+)\s*=\s*(\d+)\s*;/;
    }
}
for my $name (sort keys %expect) {
    is($seen{$name}, $expect{$name}, "$name is assigned before the main loop");
}

done_testing();
