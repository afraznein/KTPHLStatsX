#!/usr/bin/perl
# Regression for frag-context certification and for the two marker branches'
# claim rules.
#
# WHY THIS RUNS THE SHIPPED BLOCK INSTEAD OF MIRRORING IT. The defect being
# guarded is that an absent or blank property numifies to a value that is legal
# for its column, so nothing errors and every count still looks plausible. A
# harness that re-implemented the check would pass against a reverted daemon.
# The payload block is lifted out of hlstats.pl by marker and executed, so a
# revert fails here.
#
#   perl scripts/selftest-frag-context.pl        # exit 0 = pass
use strict;
use warnings;
use Test::More;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';
my $MIGRATION20 = $SCRIPT_DIR . '../sql/migrate_020_frag_context_certified.sql';

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
my $payload = between_markers($source,
    '# BEGIN KTP FRAG CONTEXT PAYLOAD',
    '# END KTP FRAG CONTEXT PAYLOAD');

our (%ev_properties_hash, $ktp_actor_player_id, $ktp_victim_player_id, @logged);
$ktp_actor_player_id = 9001;
$ktp_victim_player_id = 9002;
sub printEvent { push(@logged, join(' ', @_[0, 1])); }

# Runs the shipped block over one property set and hands back what it decided.
sub resolve {
    my (%properties) = @_;
    %ev_properties_hash = %properties;
    @logged = ();
    my $out = eval "no strict 'vars';\n$payload\n"
        . '+{ context => {%fc_context}, unusable => [@fc_unusable],'
        . '   certified => $fc_certified };';
    die "cannot run shipped frag-context payload: $@" unless $out;
    return $out;
}

my %COMPLETE = (
    headshot => '1', k_prone => '0', v_prone => '0', k_scope => '1',
    v_scope => '0', k_clip => '5', k_ammo => '40', v_clip => '8',
    v_ammo => '24', is_last_flag_defense => '0',
);

# --- what the current producer emits on every kill ---------------------------
my $complete = resolve(%COMPLETE);
is($complete->{certified}, 1, 'a complete producer payload certifies');
is_deeply($complete->{unusable}, [], 'a complete payload reports nothing unusable');
is_deeply($complete->{context},
    { headshot => 1, k_prone => 0, v_prone => 0, k_scope => 1, v_scope => 0,
      k_clip => 5, k_ammo => 40, v_clip => 8, v_ammo => 24,
      is_last_flag_defense => 0 },
    'every context property survives the round trip as an integer');
is(scalar(@logged), 0, 'a clean payload is silent');

# --- the defect this file exists for -----------------------------------------
# getProperties yields '' for (k_prone ""), and '' numifies to 0, which is
# "standing" -- a legal reading indistinguishable from a measurement.
my $blank = resolve(%COMPLETE, k_prone => '');
is($blank->{context}{k_prone}, 0, 'a blank property still lands on the column default');
is($blank->{certified}, 0, 'but a blank property withholds certification');
like($blank->{unusable}[0], qr/^k_prone=/, 'the blank property is named');
is(scalar(@logged), 1, 'an unusable property is reported, not swallowed');
like($logged[0], qr/KTP_BAD_PROPERTY/, 'it is reported as a bad property');

my %missing_clip = map { $_ => $COMPLETE{$_} }
    grep { $_ ne 'k_clip' } keys %COMPLETE;
my $absent = resolve(%missing_clip);
is($absent->{context}{k_clip}, -1, 'an absent clip falls back to the read-failed sentinel');
is($absent->{certified}, 0, 'an absent property withholds certification');
like($absent->{unusable}[0], qr/k_clip=<absent>/, 'absent is distinguished from blank');

for my $bad ('yes', '1.5', '-', ' 1') {
    my $got = resolve(%COMPLETE, is_last_flag_defense => $bad);
    is($got->{certified}, 0, "a non-integer '$bad' withholds certification");
    is($got->{context}{is_last_flag_defense}, 0, "'$bad' is not stored as a measurement");
}

# --- values that are legal and must NOT be rejected --------------------------
# -1 is the producer's own "the read failed" reading for clip and ammo, so it is
# a measurement and certifies; migration 005 says so explicitly.
my $sentinel = resolve(%COMPLETE, k_clip => '-1', k_ammo => '-1');
is($sentinel->{certified}, 1, 'an explicit -1 clip reading is a measurement, not a fault');
is($sentinel->{context}{k_clip}, -1, 'the sentinel is stored as sent');

# dod_get_pronestate is a raw state, not a bool, and real traffic carries values
# above the 0/1/2 migration 005 lists -- bound it to the column, not to that list.
my $prone = resolve(%COMPLETE, k_prone => '13');
is($prone->{certified}, 1, 'a raw pronestate beyond the documented set still certifies');
is($prone->{context}{k_prone}, 13, 'the raw pronestate is kept, not coerced to a bool');

# --- out of column range -----------------------------------------------------
my $overflow = resolve(%COMPLETE, k_ammo => '99999');
is($overflow->{certified}, 0, 'a value the column cannot hold withholds certification');
is($overflow->{context}{k_ammo}, -1, 'and is not sent to MySQL to abort the UPDATE');

# --- the SQL the two branches emit -------------------------------------------
my ($headshot_branch) = ($source =~
    /if \(\$ev_obj_a eq "headshot_kill"\) \{(.*?)\n\s*\} elsif \(\$ev_obj_a eq "frag_context"\)/s);
ok(defined($headshot_branch), 'headshot_kill branch is present');
unlike($headshot_branch, qr/frag_context_(?:recorded|certified) = 1/,
    'headshot_kill certifies nothing -- it collects no context');
like($headshot_branch, qr/ORDER BY id DESC/,
    'headshot_kill claims the newest unclaimed frag, not the oldest');
like($headshot_branch, qr/AND headshot = 0/,
    'headshot_kill keeps its own claim guard');

my ($frag_branch) = ($source =~
    /elsif \(\$ev_obj_a eq "frag_context"\) \{(.*?)\n\s*\} elsif \(\$ev_obj_a eq "damage"\)/s);
ok(defined($frag_branch), 'frag_context branch is present');
like($frag_branch, qr/frag_context_recorded = 1,\s*\r?\n\s*frag_context_certified = "\.\$fc_certified\./,
    'frag_context always claims, and certifies separately');
like($frag_branch, qr/AND frag_context_recorded = 0/,
    'the claim guard, not the certification, is what makes correlation exactly-once');
unlike($frag_branch, qr/AND frag_context_certified = 0/,
    'certification must not gate the claim, or a partial payload becomes re-claimable');

# A revert to the bare defined-or defaults is the failure mode this file guards.
unlike($frag_branch, qr/\$ev_properties_hash\{"(?:k_prone|k_clip|is_last_flag_defense)"\}\s*\/\//,
    'context properties are validated rather than defaulted with //');

# --- migration 020 -----------------------------------------------------------
my $migration20 = slurp($MIGRATION20);
like($migration20, qr/COLUMN_NAME = 'frag_context_certified'/,
    'migration 020 guards the additive column');
like($migration20, qr/ADD COLUMN frag_context_certified TINYINT\(1\) NOT NULL DEFAULT 0/,
    'existing rows default to uncertified');
unlike($migration20, qr/^\s*UPDATE\s+hlstats_Events_Frags/mi,
    'migration 020 runs no backfill -- certification cannot be re-derived from content');
like($migration20, qr/must run before daemon/i,
    'migration 020 states its ordering against the daemon');

done_testing();
