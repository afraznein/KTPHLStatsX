#!/usr/bin/perl
# Selftest for getProperties' property-tail parse loop.
#
# WHY THIS ASSERTS BOTH DIRECTIONS. A harness that cannot SEE the defect makes a
# clean corpus run worthless: the fix below is output-neutral on every real log
# line we have (32k tails, 0 differences), so a test that only checks "output
# unchanged" passes identically whether the fix is present, absent, or wrong.
# So the defect case must DIFFER and the normal cases must be SAME.
#
# The first version of this harness reported a FALSE CLEAN because Perl scopes $1
# to the enclosing block -- reading it outside the `if` that ran the match yields
# undef and every key parses empty. Captures are read immediately below.
#
#   perl scripts/selftest-getproperties.pl        # exit 0 = pass
use strict;
use warnings;

my $SRC = $0; $SRC =~ s{[^/\\]+$}{hlstats.pl};

# --- drift guard: the mirrored regex must be the one actually shipped ----------
# Without this the mirror silently becomes fiction the moment hlstats.pl changes.
my $shipped;
{
    open(my $fh, '<', $SRC) or die "cannot read $SRC: $!";
    while (my $l = <$fh>) {
        if ($l =~ /\$propstring\s*=~\s*s(.*)$/) { $shipped = $l; last; }
    }
    close $fh;
}
die "FAIL: no propstring substitution found in $SRC\n" unless defined $shipped;

my $KEY_NEW = '[^\s()]+';
my $KEY_OLD = '\S+';
unless (index($shipped, '(([^\s()]+)') >= 0) {
    print "FAIL: shipped regex does not carry the [^\\s()]+ key pattern.\n";
    print "      shipped: $shipped";
    exit 1;
}

# --- the mirror ---------------------------------------------------------------
sub parse_with {
    my ($keypat, $propstring) = @_;
    my %p;
    my $guard = 0;
    while ($propstring =~ s/^\s*\(($keypat)(?:(?: "(.*?)")|(?: ([^\)]+)))?\)//) {
        my ($key, $q, $u) = ($1, $2, $3);   # read immediately: $1 is block-scoped
        if    (defined $q) { $p{$key} = $q }
        elsif (defined $u) { $p{$key} = $u }
        else               { $p{$key} = 1  }
        last if ++$guard > 64;
    }
    return join('|', map { "$_=$p{$_}" } sort keys %p);
}

# --- fixtures ----------------------------------------------------------------
# expect: 'differ' = the fix must change the parse; 'same' = must not.
my @CASES = (
    ['differ', 'bare key followed by another property',
                '(flagindex) (map "dod_kalt")'],
    ['differ', 'two bare keys in a row',
                '(world) (flagindex) (map "dod_donner")'],
    ['same',   'lone bare boolean (the abundant real case, 246 fleet-wide)',
                '(world)'],
    ['same',   'ordinary quoted pair',
                '(matchid "42") (map "dod_avalanche")'],
    ['same',   'quoted + unquoted mix',
                '(score 5) (team "Allies")'],
    ['same',   'EMPTY quoted field -- guards the .*? fix stays working',
                '(matchid "") (map "dod_harrington")'],
);

my ($pass, $fail) = (0, 0);
for my $c (@CASES) {
    my ($want, $desc, $input) = @$c;
    my $old = parse_with($KEY_OLD, $input);
    my $new = parse_with($KEY_NEW, $input);
    my $got = ($old eq $new) ? 'same' : 'differ';
    if ($got eq $want) {
        $pass++;
        printf("  ok    %-6s  %s\n", $got, $desc);
    } else {
        $fail++;
        printf("  FAIL  want=%-6s got=%-6s  %s\n", $want, $got, $desc);
        printf("        input: %s\n        old:   %s\n        new:   %s\n", $input, $old, $new);
    }
}

# A run where nothing differs means the harness is blind, even if every case
# "passed" -- that is the failure mode this file exists to prevent.
my $differs = grep { $_->[0] eq 'differ' } @CASES;
if ($differs == 0) {
    print "FAIL: no case asserts a difference; this harness cannot see the defect.\n";
    exit 1;
}

printf("\n%d passed, %d failed (%d of them assert the defect is visible)\n",
       $pass, $fail, $differs);
exit($fail == 0 ? 0 : 1);
