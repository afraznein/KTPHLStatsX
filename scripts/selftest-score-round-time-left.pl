#!/usr/bin/perl
#
# Schema 25 puts the half clock on score rows (stats_logging 1.26.1, migration
# 039). A score row from any older producer carries no round_time_left and must
# still land, with NULL -- the live fleet runs schema 24 until the plugin swap,
# so a daemon that required the field would drop every score row in between.
#
# Runs the shipped doEvent_KTPScoreEvent against a captured execNonQuery, so what
# is asserted is the INSERT the daemon would send, column by column.

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);

my $DIR = dirname($0);
sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close($fh);
    $text =~ s/\r//g;
    return $text;
}
my $source = slurp("$DIR/hlstats.pl");

sub body_of {
    my ($name) = @_;
    my ($body) = ($source =~ /\nsub \Q$name\E\s*\{(.*?)\n\}/s);
    die "could not extract sub $name from hlstats.pl" if (!defined($body));
    return $body;
}

# --- the shipped handler, with its collaborators stubbed ----------------------
our (%g_servers, $s_addr, @sql);
$s_addr = "10.0.0.1:27015";
$g_servers{$s_addr} = { id => 9 };
sub execNonQuery { push(@sql, $_[0]); return 1; }
sub quoteSQL { my ($v) = @_; $v =~ s/'/''/g; return $v; }
sub ktpWave2Context { my ($stream, $p) = @_; $p->{_half} = $p->{half}; $p->{_map} = $p->{map}; return ""; }
sub ktpWave2Player { return (4242, 7); }
{
    no strict 'vars';
    no warnings 'redefine';
    eval "sub ktpNumOrNull {" . body_of('ktpNumOrNull') . "\n}\n"
       . "sub doEvent_KTPScoreEvent {" . body_of('doEvent_KTPScoreEvent') . "\n}\n1;"
        or die "handler eval failed: $@";
}

# Column name -> SQL literal for the one INSERT a call produced.
sub score_row {
    my (%extra) = @_;
    @sql = ();
    my %p = (matchid => "KTP-1", half => 2, map => "dod_anzio", player => "P<7><STEAM_0:1:1><Allies>",
        delta => 1, total => 11, flag_index => 3, dll_index => 3, flag_name => "church",
        identity_resolved => 1, game_time => "321.50", event_epoch => 1790000000, sequence => 55,
        %extra);
    my $status = doEvent_KTPScoreEvent(\%p);
    return (undef, $status) if (@sql != 1);
    my ($cols, $vals) = ($sql[0] =~ /INSERT IGNORE INTO ktp_score_events\s*\((.*?)\)\s*VALUES\s*\((.*)\)\s*$/s)
        or return (undef, "unparsed SQL");
    my @c = map { s/^\s+|\s+$//gr } split(/,/, $cols);
    my @v = map { s/^\s+|\s+$//gr } split(/,(?![^(]*\))/, $vals);
    return (undef, "column/value count " . scalar(@c) . "/" . scalar(@v)) if (@c != @v);
    my %row;
    @row{@c} = @v;
    return (\%row, $status);
}

my ($row, $status);

# Control: the harness reads real values, so a NULL below is the daemon's answer.
($row, $status) = score_row(round_time_left => "912.3");
ok($row, "a schema-25 score row produces one parseable INSERT") or diag($status);
is($row->{delta}, 1, "control: delta is read from the row");
is($row->{round_time_left}, 912.3, "schema 25: round_time_left is stored as sent");
like($status, qr/^Score event logged/, "schema 25: row is logged");

# Schema 21-24 (and 1.26.0) rows have no field at all. They still land, NULL.
($row, $status) = score_row();
ok($row, "a score row without round_time_left still INSERTs") or diag($status);
is($row->{round_time_left}, "NULL", "no round_time_left -> NULL, never 0");
like($status, qr/^Score event logged/, "pre-schema-25 row is logged, not dropped");

# Same NULL semantics as objective_attempt and flag_state (ktpNumOrNull).
($row) = score_row(round_time_left => "");
is($row->{round_time_left}, "NULL", "empty round_time_left -> NULL");
($row) = score_row(round_time_left => "abc");
is($row->{round_time_left}, "NULL", "malformed round_time_left -> NULL");
($row) = score_row(round_time_left => "0.0");
is($row->{round_time_left}, 0, "0.0 is a real clock value, kept");
($row) = score_row(round_time_left => "-1.0");
is($row->{round_time_left}, -1, "-1.0 (no time limit) is stored as sent, as on the other two tables");

# The flag-state writer uses the same helper for the same field; if that ever
# changes, score rows must change with it.
{
    my $flag = body_of('doEvent_KTPFlagState');
    like($flag, qr/ktpNumOrNull\(\$round_time_left\)/, "flag_state stores round_time_left through ktpNumOrNull too");
}

# --- the migration creates exactly what the daemon writes ---------------------
my $mig = slurp("$DIR/../sql/migrate_039_score_round_time_left.sql");
like($mig, qr/\A-- ENGINE: mysql /, "migration 039 declares its engine on line 1");
like($mig, qr/TABLE_NAME='ktp_score_events' AND COLUMN_NAME='round_time_left'\), 'ADD COLUMN round_time_left DECIMAL\(7,1\) DEFAULT NULL /,
    "039 adds ktp_score_events.round_time_left as DECIMAL(7,1) DEFAULT NULL, guarded by information_schema");
my $m32 = slurp("$DIR/../sql/migrate_032_wave1_additive_fields.sql");
my @types = ($m32 =~ /'ADD COLUMN round_time_left (\S+ DEFAULT NULL)/g);
is_deeply(\@types, ["DECIMAL(7,1) DEFAULT NULL", "DECIMAL(7,1) DEFAULT NULL"],
    "control: 032's two round_time_left columns are the type 039 mirrors");

done_testing();
