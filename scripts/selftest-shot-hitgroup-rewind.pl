#!/usr/bin/perl
#
# Schema 26 (stats_logging 1.27.0, migration 041): the shot row gains hitgroup
# and the per-shot rewind group, the manifest gains the sv_maxunlag in force, and
# trace_start_off leaves the wire. A schema 21-25 producer sends none of these and
# every one must land NULL, because the fleet keeps running older producers
# against this daemon until the plugin swap.
#
# Runs the shipped doEvent_KTPShot / flushShotEvents and the shipped manifest
# subs against a captured execNonQuery, so what is asserted is the SQL the
# daemon would send.

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

# --- the shipped subs, with their collaborators stubbed -----------------------
our (%g_servers, $s_addr, @sql, %g_ktpAcceptedCaptureManifests, %g_ktpMatchContext,
    @g_ktpShotQueue, $g_ktp_shot_queue_size, %g_ktpPendingLife, %g_ktpPendingDamage,
    %g_ktpCaptureSequences);
$s_addr = "10.0.0.1:27015";
$g_servers{$s_addr} = { id => 9 };
$g_ktp_shot_queue_size = 1000;
sub execNonQuery { push(@sql, $_[0]); return 1; }
sub quoteSQL { my ($v) = @_; $v =~ s/'/''/g; return $v; }
sub printEvent { }
sub ktpHasExplicitProducerContext { return 1; }
sub ktpResolveValidatedProducerEventContext { return ($_[1], "dod_anzio", "", "producer"); }
sub ktpWarnProducerClock { }
sub ktpResolveShotTargetPlayerId { return 5150; }
{
    no strict 'vars';
    no warnings 'redefine';
    my $code = "";
    for my $sub (qw(ktpCaptureContextKey doEvent_KTPShot flushShotEvents
        ktpValidateCaptureManifestPayload ktpParseCaptureMarkerEnvelope
        doEvent_KTPCaptureManifest)) {
        $code .= "sub $sub {" . body_of($sub) . "\n}\n";
    }
    eval $code . "1;" or die "handler eval failed: $@";
}

# --- manifest -----------------------------------------------------------------
my $caps = join(',', qw(frag_context damage position assist life break
    flag_state flag_position objective_attempt grenade_entity team_membership
    shot position_state map_revision sequence health));
my %m25 = (matchid => 'KTP-1', half => 1, map => 'dod_anzio', producer => 'stats_logging',
    producer_version => '1.26.3', schema => 25, capabilities => $caps,
    position_interval => '2.0', buffer_entries => 128, life_buffer_entries => 64,
    map_revision_algorithm => 'sha256', map_revision => ('a' x 64),
    sequence => 1, event_epoch => 1790000000);
my %m26 = (%m25, producer_version => '1.27.0', schema => 26, sv_maxunlag => '0.300');

is(ktpValidateCaptureManifestPayload(\%m25), '', 'schema-25 manifest still accepted');
is(ktpValidateCaptureManifestPayload(\%m26), '', 'schema-26 manifest accepted');
like(ktpValidateCaptureManifestPayload({ %m26, schema => 27 }), qr/unsupported schema/,
    'schema 27 is refused');
like(ktpValidateCaptureManifestPayload({ %m25, sv_maxunlag => '0.300' }), qr/requires schema 26/,
    'a pre-26 manifest carrying sv_maxunlag is refused, like a pre-23 revision pair');
is(ktpValidateCaptureManifestPayload({ %m26, sv_maxunlag => 'junk' }), '',
    'a malformed sv_maxunlag never refuses the manifest');
is(ktpValidateCaptureManifestPayload({ %m26, sv_maxunlag => undef }), '',
    'a schema-26 manifest without sv_maxunlag is accepted');

# Split a VALUES list on top-level commas: not inside '...' or (...).
sub split_values {
    my ($text) = @_;
    my @out;
    my ($cur, $depth, $quoted) = ('', 0, 0);
    for my $ch (split(//, $text)) {
        if ($quoted) { $quoted = 0 if ($ch eq "'"); }
        elsif ($ch eq "'") { $quoted = 1; }
        elsif ($ch eq '(') { $depth++; }
        elsif ($ch eq ')') { $depth--; }
        elsif ($ch eq ',' && $depth == 0) { push(@out, $cur); $cur = ''; next; }
        $cur .= $ch;
    }
    push(@out, $cur);
    return map { s/^\s+|\s+$//gr } @out;
}

sub wire_of {
    my ($p, @order) = @_;
    return join(' ', map { "($_ \"$p->{$_}\")" } @order);
}
my @legacy = qw(matchid half map producer producer_version schema capabilities
    position_interval buffer_entries life_buffer_entries map_revision_algorithm
    map_revision sequence event_epoch);
my @with_unlag = @legacy;
splice(@with_unlag, -2, 0, 'sv_maxunlag');
my ($parsed, $err) = ktpParseCaptureMarkerEnvelope('manifest', wire_of(\%m26, @with_unlag));
is($err, '', 'schema-26 manifest envelope (sv_maxunlag after the revision pair) parses');
is($parsed->{sv_maxunlag}, '0.300', 'envelope keeps sv_maxunlag as sent');
($parsed, $err) = ktpParseCaptureMarkerEnvelope('manifest', wire_of(\%m25, @legacy));
is($err, '', 'control: the schema-23..25 envelope still parses');
my @misplaced = @legacy;
push(@misplaced, 'sv_maxunlag');
(undef, $err) = ktpParseCaptureMarkerEnvelope('manifest', wire_of(\%m26, @misplaced));
like($err, qr/order\/schema/, 'sv_maxunlag anywhere but its slot fails the exact grammar');

sub manifest_sql {
    my ($p) = @_;
    @sql = ();
    my $status = doEvent_KTPCaptureManifest($p);
    return (undef, $status) if (@sql != 1);
    my ($cols, $vals) = ($sql[0] =~ /INSERT INTO ktp_capture_manifests\s*\((.*?)\)\s*VALUES\s*\((.*)\)\s*ON DUPLICATE/s)
        or return (undef, "unparsed SQL");
    my @c = map { s/^\s+|\s+$//gr } split(/,/, $cols);
    my @v = split_values($vals);
    return (undef, "column/value count " . scalar(@c) . "/" . scalar(@v)) if (@c != @v);
    my %row;
    @row{@c} = @v;
    return (\%row, $status, $sql[0]);
}
my ($mrow, $mstatus, $msql) = manifest_sql({ %m26 });
ok($mrow, 'schema-26 manifest produces one parseable INSERT') or diag($mstatus);
is($mrow->{sv_maxunlag}, 0.3, 'sv_maxunlag is stored as sent');
is($mrow->{schema_version}, 26, 'control: schema_version is read from the row');
like($msql, qr/sv_maxunlag=VALUES\(sv_maxunlag\)/, 'a replayed manifest refreshes sv_maxunlag');
($mrow) = manifest_sql({ %m25 });
is($mrow->{sv_maxunlag}, 'NULL', 'pre-26 manifest -> sv_maxunlag NULL');
($mrow) = manifest_sql({ %m26, sv_maxunlag => '-0.3' });
is($mrow->{sv_maxunlag}, 'NULL', 'malformed sv_maxunlag -> NULL, manifest still recorded');
($mrow) = manifest_sql({ %m26, sv_maxunlag => '0' });
is($mrow->{sv_maxunlag}, 0, '0 (lag compensation unclamped) is a real value, kept');

# --- shot rows ----------------------------------------------------------------
$g_ktpAcceptedCaptureManifests{join("\x1e", $s_addr, 'KTP-1', 1)} = { schema => 26, shot => 1 };

# One shot through doEvent_KTPShot and flushShotEvents; column name -> literal.
my @SHOT_ARGS = qw(weapon_id position yaw pitch prone map game_time event_epoch
    matchid half sequence tgt_userid tgt_health tgt_dead tgt_team shooter_team
    shot_ping shot_loss cmd_traces trace_frac trace_flags trace_start_off
    cmd_all_traces net_lerp net_dropped net_backup net_cmds shooter_flags
    shooter_punch_pitch shooter_punch_yaw shooter_speed shooter_stamina
    hitgroup rw_flags rw_depth rw_want);
my %HIT = (weapon_id => 10, position => '1 2 3', yaw => '45.20', pitch => '-3.10', prone => 0,
    map => 'dod_anzio', game_time => '245.32', event_epoch => 1790000001, matchid => 'KTP-1',
    half => 1, sequence => 7, tgt_userid => 12, tgt_health => 100, tgt_dead => 0, tgt_team => 2,
    shooter_team => 1, shot_ping => 40, shot_loss => 0, cmd_traces => 1, trace_frac => 5000,
    trace_flags => 0, cmd_all_traces => 1, net_lerp => 100, net_dropped => 0,
    net_backup => 0, net_cmds => 2, shooter_flags => 1, shooter_speed => 0,
    shooter_stamina => 100, hitgroup => 1, rw_flags => 7, rw_depth => 300, rw_want => 412);
my %MISS = (%HIT, tgt_userid => -1, tgt_health => -1, tgt_dead => -1, tgt_team => -1,
    shooter_team => -1, shot_ping => -1, shot_loss => -1, cmd_traces => -1, trace_frac => -1,
    trace_flags => -1, cmd_all_traces => -1, shooter_flags => -1, shooter_speed => -1,
    shooter_stamina => -1, hitgroup => -1);
my @RW = qw(hitgroup rw_flags rw_depth rw_want);

sub shot_row {
    my (%p) = @_;
    @sql = ();
    @g_ktpShotQueue = ();
    my $status = doEvent_KTPShot(4242, map { $p{$_} } @SHOT_ARGS);
    flushShotEvents();
    return (undef, $status) if (@sql != 1);
    my ($cols, $vals) = ($sql[0] =~ /INSERT INTO ktp_shot_events\s*\((.*?)\)\s*VALUES\s*\((.*)\)\s*ON DUPLICATE/s)
        or return (undef, "unparsed SQL");
    my @c = map { s/^\s+|\s+$//gr } split(/,/, $cols);
    my @v = split_values($vals);
    return (undef, "column/value count " . scalar(@c) . "/" . scalar(@v)) if (@c != @v);
    my %row;
    @row{@c} = @v;
    return (\%row, $status);
}
sub group { my ($row) = @_; return join(',', map { $row->{$_} } @RW); }

my ($row, $status);
($row, $status) = shot_row(%HIT);
ok($row, 'a schema-26 hit produces one parseable INSERT, columns == values') or diag($status);
is($row->{tgt_dead}, 0, 'control: target state is read from the row');
is(group($row), '1,7,300,412', 'schema-26 hit stores hitgroup and the rewind group as sent');
is($row->{trace_start_off}, 'NULL', 'schema 26 retires trace_start_off: absent -> NULL');

($row) = shot_row(%HIT, map { $_ => undef } @RW);
is(group($row), 'NULL,NULL,NULL,NULL', 'schema-25 shot (no new properties) stores all four NULL');
($row) = shot_row(%HIT, trace_start_off => 0, map { $_ => undef } @RW);
is($row->{trace_start_off}, 0, 'control: a pre-26 trace_start_off is still stored');

($row) = shot_row(%HIT, rw_flags => -1, rw_depth => -1, rw_want => -1);
is(group($row), '1,NULL,NULL,NULL', 'rw_flags -1 stores the rw group NULL, hitgroup kept');
($row) = shot_row(%HIT, rw_flags => 0, rw_depth => -1, rw_want => -1);
is(group($row), '1,0,NULL,NULL', 'bit0 clear keeps the flags (0 is real) and stores depth/want NULL');
($row) = shot_row(%HIT, rw_flags => 6, rw_depth => 300, rw_want => 412);
is(group($row), '1,6,NULL,NULL', 'depth/want are NULL whenever bit0 is clear, even if sent');
($row) = shot_row(%HIT, rw_flags => 128);
is(group($row), '1,NULL,NULL,NULL', 'rw_flags outside 0-127 voids the whole rw group');
($row) = shot_row(%HIT, rw_flags => 'x7');
is(group($row), '1,NULL,NULL,NULL', 'non-integer rw_flags voids the whole rw group');
($row) = shot_row(%HIT, rw_flags => 1, rw_depth => 0, rw_want => 0);
is(group($row), '1,1,0,0', 'depth 0 (not rewound) is a real value, kept');

($row) = shot_row(%MISS, rw_flags => 3, rw_depth => 120, rw_want => 120);
is($row->{tgt_dead}, 'NULL', 'control: a miss has no target state');
is(group($row), 'NULL,3,120,120', 'a miss keeps a populated rw group; hitgroup NULL');

($row) = shot_row(%HIT, hitgroup => 0);
is($row->{hitgroup}, 0, 'hitgroup 0 (generic) is real, kept');
($row) = shot_row(%HIT, hitgroup => 100);
is($row->{hitgroup}, 'NULL', 'hitgroup outside 0-99 -> NULL');
($row) = shot_row(%MISS, hitgroup => 2);
is($row->{hitgroup}, 'NULL', 'hitgroup without target state -> NULL');

# --- the migration creates exactly what the daemon writes ---------------------
my $mig = slurp("$DIR/../sql/migrate_041_shot_hitgroup_rewind.sql");
like($mig, qr/\A-- ENGINE: mysql /, 'migration 041 declares its engine on line 1');
for my $c (['ktp_shot_events', 'hitgroup', 'TINYINT UNSIGNED'],
           ['ktp_shot_events', 'rw_flags', 'TINYINT UNSIGNED'],
           ['ktp_shot_events', 'rw_depth', 'SMALLINT UNSIGNED'],
           ['ktp_shot_events', 'rw_want', 'SMALLINT UNSIGNED'],
           ['ktp_capture_manifests', 'sv_maxunlag', 'DECIMAL(5,3)']) {
    my ($t, $col, $type) = @$c;
    like($mig, qr/TABLE_NAME='\Q$t\E' AND COLUMN_NAME='\Q$col\E'\), 'ADD COLUMN \Q$col\E \Q$type\E DEFAULT NULL /,
        "041 adds $t.$col as $type DEFAULT NULL, guarded by information_schema");
}

done_testing();
