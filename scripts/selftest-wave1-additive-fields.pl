#!/usr/bin/perl
# Focused regression for expansion wave 1 (migration 032): the optional-field
# helpers map absent/malformed/sentinel values to NULL and never to 0, and every
# new column is both written by the daemon and created by the migration.
use strict;
use warnings;
use Test::More;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';
my $MIGRATION32 = $SCRIPT_DIR . '../sql/migrate_032_wave1_additive_fields.sql';

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close($fh);
    return $text;
}

my $source = slurp($SRC);
$source =~ s/\r//g;
my ($helpers) = $source =~ /^# BEGIN KTP WAVE-1 OPTIONAL FIELD HELPERS\n(.*?)^# END KTP WAVE-1 OPTIONAL FIELD HELPERS/ms
    or die "wave-1 helper block not found in $SRC\n";
eval "no strict 'vars';\n$helpers\n1;" or die "helper eval failed: $@";

# Absent, empty (getProperties yields "" for an empty field), junk -> NULL.
is(ktpIntOrNull(undef), "NULL", "int: absent is NULL");
is(ktpIntOrNull(""),    "NULL", "int: empty is NULL, not 0");
is(ktpIntOrNull("abc"), "NULL", "int: junk is NULL");
is(ktpIntOrNull("7.5"), "NULL", "int: float text is NULL");
is(ktpIntOrNull("0"),   0,      "int: 0 is a real value");
is(ktpIntOrNull("-3"),  -3,     "int: negative kept");
is(ktpNumOrNull(""),    "NULL", "num: empty is NULL");
is(ktpNumOrNull("12.5"), 12.5,  "num: float kept");
is(ktpNumOrNull("0.0"), 0,      "num: 0.0 is a real value");
is(ktpNonNegOrNull("-1"),   "NULL", "nonneg: producer -1 sentinel is NULL");
is(ktpNonNegOrNull("-1.00"), "NULL", "nonneg: -1.00 sentinel is NULL");
is(ktpNonNegOrNull("0"),    0,      "nonneg: 0 kept");
is(ktpNonNegOrNull("100"),  100,    "nonneg: 100 kept");
is(ktpAngleOrNull("-999.0"), "NULL", "angle: -999 sentinel is NULL");
is(ktpAngleOrNull("-179.5"), -179.5, "angle: negative real angle kept");
is(ktpAngleOrNull("0.0"),    0,      "angle: 0.0 kept");

# Every column the migration adds is one the daemon writes, per table.
my $mig = slurp($MIGRATION32);

# Each ADD COLUMN lives inside a single-quoted SQL literal that is PREPAREd
# later, so an apostrophe in a COMMENT needs four quotes, not two. One stray
# quote broke the ktp_flag_positions ALTER on Lane B (run 35181701156).
while ($mig =~ /'(ADD COLUMN .*?)', NULL\)/g) {
    my $raw = $1;
    (my $ddl = $raw) =~ s/''/'/g;   # what PREPARE actually sees
    my $quotes = () = $ddl =~ /'/g;
    ok($quotes == 0 || $quotes == 2,
        "COMMENT has no inner apostrophe in: " . substr($raw, 0, 60));
}
my %added;
while ($mig =~ /TABLE_NAME='(\w+)' AND COLUMN_NAME='(\w+)'\), 'ADD COLUMN \2 /g) {
    push(@{$added{$1}}, $2);
}
is(scalar(keys %added), 6, "migration touches 6 tables");
my %writer = (
    ktp_objective_attempt_events => qr/INSERT INTO ktp_objective_attempt_events\s*\((.*?)\)\s*VALUES/s,
    ktp_damage_events            => qr/INSERT INTO ktp_damage_events\s*\((.*?)\)\s*VALUES/s,
    ktp_life_events              => qr/INSERT IGNORE INTO ktp_life_events\s*\((.*?)\)\s*VALUES/s,
    ktp_flag_state_events        => qr/INSERT IGNORE INTO ktp_flag_state_events\s*\((.*?)\)\s*VALUES/s,
    ktp_flag_positions           => qr/INSERT INTO ktp_flag_positions\s*\((.*?)\)\s*VALUES/s,
    hlstats_Events_Frags         => qr/UPDATE hlstats_Events_Frags\s*SET(.*?frag_context_recorded = 1.*?)WHERE/s,
);
for my $table (sort keys %added) {
    my ($cols) = $source =~ $writer{$table} or die "no writer for $table";
    for my $col (@{$added{$table}}) {
        like($cols, qr/\b\Q$col\E\b/, "$table.$col written by daemon");
    }
}
# Upsert path must refresh the flag metadata too, or a remap keeps stale values.
my ($upsert) = $source =~ /INSERT INTO ktp_flag_positions.*?ON DUPLICATE KEY UPDATE(.*?)"\);/s;
like($upsert, qr/\$meta_set/, "flag_position upsert refreshes wave-1 metadata");

done_testing();
