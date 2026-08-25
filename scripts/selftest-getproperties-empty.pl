#!/usr/bin/perl
# Regression for the VALUE branch of getProperties: an EMPTY quoted field must
# parse as ABSENT, not as a present "" value.
#
# Why absent and not "": every consumer defaults with `//`, and defined-or sees
# "" as a value -- which then NUMIFIES to 0. A blank k_prone read as "standing"
# and a blank k_clip as an empty magazine instead of the -1 read-failed
# sentinel, and a half with no real data read as a complete one. Reachable
# without a malformed producer, because formatex truncates markers tail-first.
#
# selftest-getproperties.pl varies the KEY pattern only and holds the value
# branch constant, so it cannot see this defect (its own header says so). This
# file executes the REAL sub, extracted from hlstats.pl, so a revert of either
# the regex or the storage guard fails here rather than silently passing.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $SRC = dirname($0) . '/hlstats.pl';

my $source;
{
    open(my $fh, '<', $SRC) or die "cannot read $SRC: $!";
    local $/;
    $source = <$fh>;
    close($fh);
}

# Extract the whole sub: from its header to the first close brace at column 0.
# No mirror -- the code under test is the code that ships. \r?-tolerant because
# this tree checks out CRLF on Windows while the deployed copy is LF.
my ($fn) = $source =~ /^(sub getProperties\r?\n\{.*?\r?\n\})/ms;
die "could not extract sub getProperties from $SRC" unless defined $fn;
eval "$fn; 1" or die "could not load getProperties: $@";

# --- the defect case ---------------------------------------------------------
{
    my %p = getProperties('(matchid "") (map "dod_harrington")');
    ok(!exists $p{matchid},
       'empty quoted field is ABSENT, not a present "" value');
    is($p{map}, 'dod_harrington',
       'the property after the empty field still parses (the .*? regex fix holds)');
}
{
    my %p = getProperties('(k_prone "") (k_clip "") (headshot "1")');
    ok(!exists $p{k_prone},
       'blank k_prone is absent, so `// 0` cannot read it as "standing"');
    ok(!exists $p{k_clip},
       'blank k_clip is absent, so `// -1` keeps the read-failed sentinel');
    is($p{headshot}, '1', 'a real value beside the blanks is untouched');
    is($p{k_prone} // 0, 0, 'the consumer default fires for a blank field');
    is($p{k_clip} // -1, -1, 'the sentinel default fires for a blank field');
}

# --- values that must NOT be treated as absent -------------------------------
{
    my %p = getProperties('(score "0") (team "Allies") (delta -1)');
    is($p{score}, '0', 'quoted "0" is a VALUE -- only the empty string is absent');
    is($p{team}, 'Allies', 'ordinary quoted pair');
    is($p{delta}, '-1', 'unquoted value untouched');
}
{
    my %p = getProperties('(world)');
    is($p{world}, 1, 'bare boolean key still stores 1');
}

# --- the DoD:S player_a/player_b rename must survive the guard ---------------
{
    my %p = getProperties('(flagindex "3") (player "alpha") (player "bravo")');
    is($p{flagindex}, '3', 'flagindex value kept');
    is($p{player_a}, 'alpha', 'first player renamed player_a');
    is($p{player_b}, 'bravo', 'second player renamed player_b');
}
{
    # An empty first player must still advance the rename counter, or the
    # second player would be mis-keyed as player_a.
    my %p = getProperties('(flagindex "3") (player "") (player "bravo")');
    ok(!exists $p{player_a}, 'empty first player is absent');
    is($p{player_b}, 'bravo', 'rename counter advanced past the empty field');
}

done_testing();
