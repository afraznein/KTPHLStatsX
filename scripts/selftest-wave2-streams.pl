#!/usr/bin/perl
# Focused regression for expansion wave 2 (migration 033): every column the
# daemon writes for score/duel/player_state exists in the migration's CREATE
# TABLE, every non-defaulted column is written, and each stream is dispatched
# through the capture-health observe/reject pair under its health-type name.
use strict;
use warnings;
use Test::More;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';
my $MIGRATION33 = $SCRIPT_DIR . '../sql/migrate_033_wave2_streams.sql';
my $MIGRATION34 = $SCRIPT_DIR . '../sql/migrate_034_grenade_throw_events.sql';

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
my $mig = slurp($MIGRATION33) . slurp($MIGRATION34);
$mig =~ s/\r//g;

my %created;
while ($mig =~ /CREATE TABLE IF NOT EXISTS (\w+) \((.*?)\n\) ENGINE/sg) {
    my ($table, $body) = ($1, $2);
    for my $line (split(/\n/, $body)) {
        next if ($line =~ /^\s*(?:PRIMARY|UNIQUE|KEY|\)|$)/);
        next unless ($line =~ /^\s*(\w+)\s+\w/);
        my $col = $1;
        my $defaulted = ($line =~ /AUTO_INCREMENT|DEFAULT/) ? 1 : 0;
        $created{$table}{$col} = $defaulted;
    }
}
is_deeply([sort keys %created], [qw(ktp_duel_stats ktp_grenade_throw_events ktp_player_state_events ktp_score_events)],
    "migrations 033+034 create the four tables");

my %stream = (
    ktp_score_events        => ["score",        "KTP_SCORE_EVENT"],
    ktp_duel_stats          => ["duel",         "KTP_DUEL"],
    ktp_player_state_events => ["player_state", "KTP_PLAYER_STATE"],
    ktp_grenade_throw_events => ["grenade_throw", "KTP_GRENADE_THROW"],
);
for my $table (sort keys %stream) {
    my ($type, $marker) = @{$stream{$table}};
    my ($cols) = $source =~ /INSERT IGNORE INTO \Q$table\E\s*\((.*?)\)\s*VALUES/s
        or die "no INSERT for $table";
    my @written = $cols =~ /(\w+)/g;
    for my $col (@written) {
        ok(exists $created{$table}{$col}, "$table.$col exists in migration 033");
    }
    my %w = map { $_ => 1 } @written;
    for my $col (sort keys %{$created{$table}}) {
        next if ($created{$table}{$col});
        ok($w{$col}, "$table.$col (NOT NULL, no default) is written");
    }
    like($source, qr/\Q$marker\E\\s\+\(\.\*\)\$\/\) \{.*?ktpObserveCaptureMarker\("\Q$type\E"/s,
        "$marker observed as capture type '$type'");
    like($source, qr/ktpRejectCaptureMarker\("\Q$type\E", \\%ev_properties,\s*\$ev_properties\{"_ktp_correlation_failure"\}/s,
        "$marker rejection carries the correlation-failure flag");
}

# The health validator must accept the three new type names or every wave-2
# health row is dropped as "unknown event type".
my ($allowed) = $source =~ /my %allowed = map \{ \$_ => 1 \} qw\(([^)]*)\)/
    or die "health allowed set not found";
for my $type (qw(score duel player_state grenade_throw)) {
    like($allowed, qr/\b\Q$type\E\b/, "capture health accepts '$type'");
}

done_testing();
