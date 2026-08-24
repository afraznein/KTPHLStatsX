#!/usr/bin/perl
# Regression for the damage-absence distinction: a half with no per-hit ledger
# must publish NULL, not a measured 0.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $SRC = dirname($0) . '/hlstats.pl';

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

# Execute the real function rather than mirroring it, so a revert fails here.
my $fn = between_markers($source, '# KTP_DAMAGE_EXPR_BEGIN', '# KTP_DAMAGE_EXPR_END');
eval "$fn; 1" or die "could not load ktpDamageExpr: $@";

is(ktpDamageExpr(0), 'NULL',
   'no ledger rows for the half yields NULL, so absence is not published as a measured zero');
is(ktpDamageExpr(1), 'COALESCE(dmg.damage, 0)',
   'ledger present keeps COALESCE, so a player who dealt no damage still records 0');

# The distinction only holds if the caller actually uses the expression.
like($source, qr/COALESCE\(s\.suicides, 0\), \$damage_expr, 0/,
     'the INSERT interpolates $damage_expr rather than a hardcoded COALESCE');
unlike($source, qr/COALESCE\(s\.suicides, 0\), COALESCE\(dmg\.damage, 0\), 0/,
       'the unconditional COALESCE is gone from the INSERT');

# Scoped to match AND half, or one captured half makes an uncaptured one look captured.
like($source, qr/SELECT 1 FROM ktp_damage_events/,
     'the ledger is probed before choosing the expression');
like($source, qr/WHERE match_id = '\$q_matchid' AND half = \$half_num\s*\n\s*LIMIT 1/,
     'the probe is scoped to match_id AND half');

done_testing();
