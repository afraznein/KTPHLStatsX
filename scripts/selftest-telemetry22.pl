#!/usr/bin/perl
# Schema-22 contract regression for objective attempts and honest grenade
# entity lifecycle facts. Executes the shipped validators/handlers directly.
use strict;
use warnings;
use Test::More;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';
my $MIGRATION22 = $SCRIPT_DIR . '../sql/migrate_022_objective_attempts_grenade_entities.sql';

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
my $clocks = between_markers($source,
    '# BEGIN KTP LIFE BOUNDARY VALIDATION',
    '# END KTP LIFE BOUNDARY VALIDATION');
my $manifest = between_markers($source,
    '# BEGIN KTP CAPTURE MANIFEST VALIDATION',
    '# END KTP CAPTURE MANIFEST VALIDATION');
my $manifest_persistence = between_markers($source,
    '# BEGIN KTP CAPTURE MANIFEST PERSISTENCE',
    '# END KTP CAPTURE MANIFEST PERSISTENCE');
my $authorization = between_markers($source,
    '# BEGIN KTP CAPTURE AUTHORIZATION',
    '# END KTP CAPTURE AUTHORIZATION');
my $observation = between_markers($source,
    '# BEGIN KTP CAPTURE SEQUENCE OBSERVATION',
    '# END KTP CAPTURE SEQUENCE OBSERVATION');
my $telemetry = between_markers($source,
    '# BEGIN KTP TELEMETRY 22 VALIDATION AND LEDGERS',
    '# END KTP TELEMETRY 22 VALIDATION AND LEDGERS');
my $health = between_markers($source,
    '# BEGIN KTP CAPTURE HEALTH VALIDATION',
    '# END KTP CAPTURE HEALTH VALIDATION');

our (%g_servers, %g_ktpCaptureSequences, %g_ktpAcceptedCaptureManifests,
     $s_addr, @query_rows, @query_batches, $query_count, $insert_count,
     $exec_return,
     $last_query, $last_insert, $context_error, $context_map);
$s_addr = '127.0.0.1:27015';
%g_servers = ($s_addr => { id => 42 });
$context_error = '';
$context_map = 'dod_anzio';
$exec_return = 1;

sub quoteSQL {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/\\'/g;
    return $value;
}
sub printEvent { return 1; }
sub ktpResolveValidatedProducerEventContext {
    my ($matchid, $half) = @_;
    return (undef, undef, $context_error, undef) if $context_error ne '';
    return (int($half), $context_map, '', 'selftest-interval');
}

{
    package Telemetry22FakeResult;
    sub new { my ($class, $rows) = @_; bless { rows => [@$rows] }, $class; }
    sub fetchrow_hashref { my ($self) = @_; return shift @{$self->{rows}}; }
    sub finish { return 1; }
}
sub doQuery {
    my ($query) = @_;
    $query_count++;
    $last_query = $query;
    my $rows = @query_batches ? shift(@query_batches) : \@query_rows;
    return Telemetry22FakeResult->new($rows);
}
sub execNonQuery {
    my ($query) = @_;
    $insert_count++;
    $last_insert = $query;
    return $exec_return;
}

my $loaded = eval "no strict 'vars';\n$clocks\n$manifest\n$manifest_persistence\n$authorization\n$observation\n$telemetry\n$health\n1;";
die "cannot load shipped telemetry helpers: $@" unless $loaded;

my $capabilities = join(',', qw(frag_context damage position assist life break
    flag_state flag_position objective_attempt grenade_entity sequence health));
my %manifest_ok = (
    matchid => 'telemetry-TEST', half => 1, map => 'dod_anzio',
    producer => 'stats_logging', producer_version => '1.18.0', schema => 22,
    capabilities => $capabilities, position_interval => '2.0',
    buffer_entries => 128, life_buffer_entries => 64,
    sequence => 1, event_epoch => 1787616774,
);
is(ktpValidateCaptureManifestPayload(\%manifest_ok), '',
    'schema-22 manifest accepts the two-second paired contract');
for my $bad_schema (21, 23) {
    my %bad = (%manifest_ok, schema => $bad_schema);
    like(ktpValidateCaptureManifestPayload(\%bad), qr/schema/,
        "schema $bad_schema is rejected by the schema-22 receiver");
}
my %bad_interval = (%manifest_ok, position_interval => '1.0');
like(ktpValidateCaptureManifestPayload(\%bad_interval), qr/position_interval/,
    'one-second manifest is rejected by the two-second contract');
my %missing_cap = (%manifest_ok,
    capabilities => join(',', grep { $_ ne 'grenade_entity' } split(/,/, $capabilities)));
like(ktpValidateCaptureManifestPayload(\%missing_cap), qr/grenade_entity/,
    'manifest must advertise grenade entity health');

my $manifest_wire = join(' ',
    '(matchid "telemetry-TEST")', '(half "1")', '(map "dod_anzio")',
    '(producer "stats_logging")', '(producer_version "1.18.0")',
    '(schema "22")', qq{(capabilities "$capabilities")},
    '(position_interval "2.0")', '(buffer_entries "128")',
    '(life_buffer_entries "64")', '(sequence "1")',
    '(event_epoch "1787616774")');
my ($parsed_manifest, $envelope_error) =
    ktpParseCaptureMarkerEnvelope('manifest', $manifest_wire);
is($envelope_error, '', 'bounded exact manifest grammar parses');
is_deeply($parsed_manifest, \%manifest_ok,
    'manifest envelope preserves the exact producer fields');
my ($ignored, $too_long) = ktpParseCaptureMarkerEnvelope(
    'manifest', $manifest_wire . (' ' x 1100));
like($too_long, qr/exceeds 1024/, 'oversized bare marker is rejected before state');
my $out_of_order = $manifest_wire;
$out_of_order =~ s/^\(matchid "telemetry-TEST"\) \(half "1"\)/(half "1") (matchid "telemetry-TEST")/;
(undef, my $order_error) =
    ktpParseCaptureMarkerEnvelope('manifest', $out_of_order);
like($order_error, qr/order\/schema/, 'out-of-order fields fail exact grammar');
(undef, my $grammar_error) = ktpParseCaptureMarkerEnvelope(
    'manifest', $manifest_wire . ' forged-tail');
like($grammar_error, qr/grammar/, 'trailing forged bytes fail exact grammar');

%g_ktpCaptureSequences = ();
%g_ktpAcceptedCaptureManifests = ();
for my $n (1 .. 1000) {
    my %forged = (matchid => "forged-$n", half => 1, sequence => $n);
    ktpObserveCaptureMarker('objective_attempt', \%forged);
}
is(scalar(keys %g_ktpCaptureSequences), 0,
    'unmanifested marker flood cannot allocate sequence state');
my %schema21 = (%manifest_ok, schema => 21);
ok(!ktpAuthorizeCaptureManifest(\%schema21),
    'schema-21 manifest cannot authorize schema-22 telemetry');
ktpObserveCaptureMarker('manifest', \%schema21);
is(scalar(keys %g_ktpAcceptedCaptureManifests), 0,
    'invalid schema manifest does not initialize authorization');
is(scalar(keys %g_ktpCaptureSequences), 0,
    'invalid schema manifest does not initialize sequence state');
my %schema23 = (%manifest_ok, schema => 23);
ok(!ktpAuthorizeCaptureManifest(\%schema23),
    'schema-23 manifest cannot authorize schema-22 telemetry');
ok(ktpAuthorizeCaptureManifest(\%manifest_ok),
    'accepted schema-22 manifest authorizes its exact context');
ktpObserveCaptureMarker('manifest', \%manifest_ok);
my $accepted_key = join("\x1e", $s_addr, 'telemetry-TEST', 1);
is(scalar(keys %g_ktpCaptureSequences), 1,
    'accepted manifest initializes exactly one sequence state');
like($g_ktpAcceptedCaptureManifests{$accepted_key}{fingerprint},
    qr/^\d+:/, 'accepted authorization stores a canonical manifest fingerprint');
ok(ktpCaptureManifestAuthorizes(\%manifest_ok, 'objective_attempt') &&
   ktpCaptureManifestAuthorizes(\%manifest_ok, 'grenade_entity'),
    'accepted capabilities authorize both new event types');
my %observed_objective = (matchid => 'telemetry-TEST', half => 1, sequence => 2);
ktpObserveCaptureMarker('objective_attempt', \%observed_objective);
ok(!ktpRevokeReplacedCaptureManifest(\%manifest_ok),
    'exact accepted manifest replay preserves authorization and sequence state');
ktpObserveCaptureMarker('manifest', \%manifest_ok);
is($g_ktpCaptureSequences{$accepted_key}{received}, 1,
    'an exact manifest replay cannot erase already observed event counts');
is($g_ktpCaptureSequences{$accepted_key}{last}, 2,
    'an exact manifest replay preserves the sequence high-water mark');

ok(ktpRevokeReplacedCaptureManifest(\%schema23),
    'non-identical schema-23 replacement revokes accepted schema-22 contract');
ok(!ktpCaptureManifestAuthorizes(\%manifest_ok, 'objective_attempt'),
    'schema-23 replacement leaves telemetry unauthorized when validation fails');
ok(!exists($g_ktpCaptureSequences{$accepted_key}),
    'schema-23 replacement revokes its sequence state before validation');
ktpObserveCaptureMarker('objective_attempt', \%observed_objective);
ok(!exists($g_ktpCaptureSequences{$accepted_key}),
    'telemetry after an invalid replacement cannot reinitialize observation state');

ok(ktpAuthorizeCaptureManifest(\%manifest_ok),
    'known-good manifest can explicitly reauthorize after invalid replacement');
ktpObserveCaptureMarker('manifest', \%manifest_ok);
my %sql_failure_manifest = (
    %manifest_ok, sequence => 3, event_epoch => $manifest_ok{event_epoch} + 1,
);
ok(ktpRevokeReplacedCaptureManifest(\%sql_failure_manifest),
    'non-identical valid replacement revokes before SQL persistence');
$exec_return = undef;
like(doEvent_KTPCaptureManifest(\%sql_failure_manifest), qr/SQL failed/,
    'replacement manifest SQL failure is exposed');
ok(!ktpCaptureManifestAuthorizes(\%manifest_ok, 'objective_attempt'),
    'failed replacement persistence leaves the prior contract revoked');
ktpObserveCaptureMarker('objective_attempt', \%observed_objective);
ok(!exists($g_ktpCaptureSequences{$accepted_key}),
    'telemetry after replacement SQL failure remains unauthorized');
$exec_return = 1;

ok(ktpAuthorizeCaptureManifest(\%manifest_ok),
    'known-good manifest can reauthorize after persistence failure');
ktpObserveCaptureMarker('manifest', \%manifest_ok);
ktpObserveCaptureMarker('objective_attempt', \%observed_objective);
my $gaps_before_unobserved_reject =
    $g_ktpCaptureSequences{$accepted_key}{gaps};
my %semantic_reject = (
    matchid => 'telemetry-TEST', half => 1, sequence => 999,
);
ktpRejectUnobservedCaptureMarker(
    'objective_attempt', \%semantic_reject, 0);
is($g_ktpCaptureSequences{$accepted_key}{received}, 2,
    'authorized semantic rejection is included in received health accounting');
is($g_ktpCaptureSequences{$accepted_key}{types}{objective_attempt}, 2,
    'authorized semantic rejection is included in per-type health accounting');
is($g_ktpCaptureSequences{$accepted_key}{rejected}{objective_attempt}, 1,
    'authorized semantic rejection increments the rejection counter');
is($g_ktpCaptureSequences{$accepted_key}{last}, 2,
    'semantic rejection cannot advance the sequence high-water mark');
is($g_ktpCaptureSequences{$accepted_key}{gaps},
    $gaps_before_unobserved_reject,
    'semantic rejection cannot manufacture sequence gaps');
my %other_context = (%manifest_ok, matchid => 'other-TEST');
ok(!ktpCaptureManifestAuthorizes(\%other_context, 'objective_attempt'),
    'authorization is scoped to server, match, and half');

# Even accepted context churn remains process-lifetime bounded.
%g_ktpCaptureSequences = ();
%g_ktpAcceptedCaptureManifests = ();
for my $n (1 .. 513) {
    my %valid = (%manifest_ok, matchid => "bounded-$n-TEST");
    ktpAuthorizeCaptureManifest(\%valid);
    ktpObserveCaptureMarker('manifest', \%valid);
}
cmp_ok(scalar(keys %g_ktpAcceptedCaptureManifests), '<=', 512,
    'accepted-manifest authorization state is bounded');
cmp_ok(scalar(keys %g_ktpCaptureSequences), '<=', 512,
    'accepted-manifest sequence state is bounded with authorization');

my %objective = (
    kind => 'start', matchid => 'telemetry-TEST', half => 1, map => 'dod_anzio',
    attempt_id => 10, flag_index => 2, flag_name => 'Bridge',
    capturing_team => 1, owner_before => 2, allies_in_zone => 1,
    axis_in_zone => 0, stop_reason => '', game_time => '12.25',
    event_epoch => 1787616774, sequence => 10,
);
is(ktpValidateObjectiveAttemptPayload(\%objective), '',
    'representative objective start validates');
for my $bad_kind (qw(begin ended)) {
    my %bad = (%objective, kind => $bad_kind);
    like(ktpValidateObjectiveAttemptPayload(\%bad), qr/event kind/,
        "invalid objective kind $bad_kind is rejected");
}
my %bad_team = (%objective, capturing_team => 0);
like(ktpValidateObjectiveAttemptPayload(\%bad_team), qr/capturing_team/,
    'neutral capturing team is rejected');
my %same_owner = (%objective, owner_before => 1);
like(ktpValidateObjectiveAttemptPayload(\%same_owner), qr/already owns/,
    'attempt against an already-owned objective is rejected');
my %no_start_occupancy = (%objective, allies_in_zone => 0);
like(ktpValidateObjectiveAttemptPayload(\%no_start_occupancy), qr/no player/,
    'start requires positive capturing-team occupancy');
my %bad_count = (%objective, axis_in_zone => -1);
like(ktpValidateObjectiveAttemptPayload(\%bad_count), qr/axis_in_zone/,
    'negative zone count is rejected');
my %bad_start_id = (%objective, attempt_id => 9);
like(ktpValidateObjectiveAttemptPayload(\%bad_start_id), qr/start attempt_id/,
    'start attempt id must be its producer sequence');

my %complete = (%objective, kind => 'complete', sequence => 11,
    allies_in_zone => 0, axis_in_zone => 0, stop_reason => '');
is(ktpValidateObjectiveAttemptPayload(\%complete), '',
    'completion may observe cleared occupancy');
my %stop = (%complete, kind => 'stop', stop_reason => 'capture_stopped');
is(ktpValidateObjectiveAttemptPayload(\%stop), '',
    'capture_stopped terminal validates');
$stop{stop_reason} = 'context_reset';
is(ktpValidateObjectiveAttemptPayload(\%stop), '',
    'context_reset terminal validates');
$stop{stop_reason} = 'timeout';
like(ktpValidateObjectiveAttemptPayload(\%stop), qr/stop_reason/,
    'unknown stop cause is rejected');
my %reason_on_complete = (%complete, stop_reason => 'capture_stopped');
like(ktpValidateObjectiveAttemptPayload(\%reason_on_complete), qr/only valid/,
    'non-stop row cannot carry a stop cause');

@query_rows = ();
$insert_count = 0;
like(doEvent_KTPObjectiveAttempt(\%complete), qr/logged/,
    'left-censored terminal is accepted without inventing a start');
is($insert_count, 1, 'left-censored terminal inserts exactly one factual row');
unlike($last_insert, qr/INSERT.*start/is,
    'terminal insert does not synthesize a start row');

my %complete_row = (
    match_id => $complete{matchid}, half => 1, map_name => $complete{map},
    attempt_id => 10, event_kind => 'complete', lifecycle_slot => 1,
    flag_index => 2, flag_name => 'Bridge', capturing_team => 1,
    owner_before => 2, allies_in_zone => 0, axis_in_zone => 0,
    stop_reason => undef, game_time => '12.25',
    event_epoch => 1787616774, producer_sequence => 11,
);
@query_rows = ({ %complete_row });
$insert_count = 0;
like(doEvent_KTPObjectiveAttempt(\%complete), qr/duplicate ignored/,
    'identical objective replay is a no-op');
is($insert_count, 0, 'identical objective replay does not write');
@query_batches = ([], [{ %complete_row }]);
$exec_return = undef;
$insert_count = 0;
like(doEvent_KTPObjectiveAttempt(\%complete), qr/duplicate ignored after concurrent insert/,
    'unique-key race reselects and accepts only a complete identical objective row');
is($insert_count, 1, 'concurrent objective replay attempts one insert before reselect');
$exec_return = 1;
@query_batches = ();
@query_rows = ({ %complete_row, event_kind => 'stop', stop_reason => 'capture_stopped' });
like(doEvent_KTPObjectiveAttempt(\%complete), qr/conflict rejected/,
    'conflicting terminal for one attempt is rejected');

my %start_row = (
    match_id => $objective{matchid}, half => 1, map_name => $objective{map},
    attempt_id => 10, event_kind => 'start', lifecycle_slot => 0,
    flag_index => 2, flag_name => 'Bridge', capturing_team => 1,
    owner_before => 2, allies_in_zone => 1, axis_in_zone => 0,
    stop_reason => undef, game_time => '12.25',
    event_epoch => 1787616774, producer_sequence => 10,
);
@query_rows = ({ %complete_row });
$insert_count = 0;
like(doEvent_KTPObjectiveAttempt(\%objective), qr/logged/,
    'reordered start is accepted after its terminal');
is($insert_count, 1, 'reordered start adds only the missing start fact');
@query_rows = ({ %complete_row, flag_index => 3 });
like(doEvent_KTPObjectiveAttempt(\%objective), qr/lifecycle identity differs/,
    'reordered lifecycle with a conflicting objective is rejected');
$context_error = 'found 0 event-time match intervals';
@query_rows = ();
$insert_count = 0;
like(doEvent_KTPObjectiveAttempt(\%objective), qr/dropped/,
    'objective event without proven producer context fails closed');
ok($objective{_ktp_correlation_failure},
    'objective context failure is exposed to health reconciliation');
is($insert_count, 0, 'context failure cannot write an objective row');
$context_error = '';

my %grenade = (
    kind => 'tracked', matchid => 'telemetry-TEST', half => 1,
    map => 'dod_anzio', entindex => 77, serial => 5,
    weapon_id => 13, weapon_type => 'handgrenade',
    owner => 'Bot 01<1><BOT><Allies>', position => '100 -200 300',
    game_time => '20.50', event_epoch => 1787616782, sequence => 12,
);
is(ktpValidateGrenadeEntityPayload(\%grenade), '',
    'tracked hand grenade validates');
my %zero_serial = (%grenade, serial => 0);
like(ktpValidateGrenadeEntityPayload(\%zero_serial), qr/serial/,
    'zero cannot identify a tracked entity generation');
for my $weapon ([14, 'stickgrenade'], [36, 'mills_bomb']) {
    my %valid = (%grenade, weapon_id => $weapon->[0], weapon_type => $weapon->[1]);
    is(ktpValidateGrenadeEntityPayload(\%valid), '',
        "grenade weapon $weapon->[0]/$weapon->[1] validates");
}
for my $forbidden (29, 30, 31, 40, 12) {
    my %bad = (%grenade, weapon_id => $forbidden);
    like(ktpValidateGrenadeEntityPayload(\%bad), qr/unsupported/,
        "rocket/mortar/other weapon $forbidden is rejected");
}
my %wrong_name = (%grenade, weapon_type => 'stickgrenade');
like(ktpValidateGrenadeEntityPayload(\%wrong_name), qr/mismatch/,
    'weapon id and canonical name must agree');
for my $dishonest (qw(detonated exploded)) {
    my %bad = (%grenade, kind => $dishonest);
    like(ktpValidateGrenadeEntityPayload(\%bad), qr/entity kind/,
        "dishonest $dishonest terminology is not accepted");
}

my %removed = (%grenade, kind => 'removed', position => '110 -190 290',
    game_time => '22.00', event_epoch => 1787616784, sequence => 13);
@query_rows = ();
$insert_count = 0;
like(doEvent_KTPGrenadeEntity(\%removed, 9001, 1), qr/logged/,
    'left-censored removed event is accepted without a tracked row');
is($insert_count, 1, 'left-censored removal inserts exactly one row');

my %removed_row = (
    match_id => $removed{matchid}, half => 1, map_name => $removed{map},
    entity_kind => 'removed', lifecycle_slot => 1, entindex => 77, serial => 5,
    weapon_id => 13, weapon_type => 'handgrenade', owner_player_id => 9001,
    owner_engine_userid => 1, pos_x => 110, pos_y => -190, pos_z => 290,
    game_time => '22.00', event_epoch => 1787616784, producer_sequence => 13,
);
@query_rows = ({ %removed_row });
$insert_count = 0;
like(doEvent_KTPGrenadeEntity(\%removed, 9001, 1), qr/duplicate ignored/,
    'identical grenade removal replay is a no-op');
is($insert_count, 0, 'identical grenade replay does not write');
@query_batches = ([], [{ %removed_row }]);
$exec_return = undef;
$insert_count = 0;
like(doEvent_KTPGrenadeEntity(\%removed, 9001, 1),
    qr/duplicate ignored after concurrent insert/,
    'unique-key race reselects and accepts only a complete identical grenade row');
is($insert_count, 1, 'concurrent grenade replay attempts one insert before reselect');
$exec_return = 1;
@query_batches = ();
@query_rows = ({ %removed_row, pos_x => 999 });
like(doEvent_KTPGrenadeEntity(\%removed, 9001, 1), qr/conflict rejected/,
    'conflicting duplicate removal is rejected');
@query_rows = ({ %removed_row });
$insert_count = 0;
like(doEvent_KTPGrenadeEntity(\%grenade, 9001, 1), qr/logged/,
    'reordered tracked fact is accepted after removed');
is($insert_count, 1, 'reordered grenade fact adds only the missing kind');
@query_rows = ({ %removed_row, weapon_id => 14, weapon_type => 'stickgrenade' });
like(doEvent_KTPGrenadeEntity(\%grenade, 9001, 1), qr/lifecycle identity differs/,
    'grenade identity cannot change weapon across lifecycle');
like(doEvent_KTPGrenadeEntity(\%grenade, 0, 1), qr/invalid resolved owner/,
    'unresolved grenade owner fails closed');
$context_error = 'producer half disagrees with event-time interval';
@query_rows = ();
like(doEvent_KTPGrenadeEntity(\%grenade, 9001, 1), qr/dropped/,
    'grenade event without proven producer context fails closed');
ok($grenade{_ktp_correlation_failure},
    'grenade context failure is exposed to health reconciliation');
$context_error = '';

my %health_ok = (
    matchid => 'telemetry-TEST', half => 1, event_type => 'objective_attempt',
    attempted => 1, enqueued => 1, dropped => 0, emitted => 1,
    sequence_first => 1, sequence_last => 13, sequence => 14,
    event_epoch => 1787616790,
);
is(ktpValidateCaptureHealthPayload(\%health_ok), '',
    'objective_attempt is a valid health type');
$health_ok{event_type} = 'grenade_entity';
is(ktpValidateCaptureHealthPayload(\%health_ok), '',
    'grenade_entity is a valid health type');

like($source, qr/KTP_OBJECTIVE_ATTEMPT.*?ktpObserveCaptureMarker\("objective_attempt"/s,
    'direct objective marker participates in capture health');
my $manifest_at = index($source, '} elsif ($s_output =~ /^KTP_CAPTURE_MANIFEST');
my $health_at = index($source, '} elsif ($s_output =~ /^KTP_CAPTURE_HEALTH');
ok($manifest_at >= 0 && $health_at > $manifest_at,
    'manifest parser branch precedes capture health');
my $manifest_branch = substr($source, $manifest_at, $health_at - $manifest_at);
my @manifest_order = map { index($manifest_branch, $_) } (
    'ktpParseCaptureMarkerEnvelope', 'ktpRevokeReplacedCaptureManifest',
    'doEvent_KTPCaptureManifest', 'ktpAuthorizeCaptureManifest',
    'ktpObserveCaptureMarker');
ok(!grep({ $_ < 0 } @manifest_order) &&
   join(',', @manifest_order) eq join(',', sort { $a <=> $b } @manifest_order),
    'replacement manifest revokes before validation/persistence and reauthorizes only afterward');
my $objective_at = index($source, '} elsif ($s_output =~ /^KTP_OBJECTIVE_ATTEMPT');
my $grenade_at = index($source, '} elsif ($s_output =~ /^KTP_GRENADE_ENTITY');
my $flag_at = index($source, '} elsif ($s_output =~ /^KTP_FLAG_POSITION');
ok($objective_at >= 0 && $grenade_at > $objective_at && $flag_at > $grenade_at,
    'direct telemetry parser branches are present in dispatch order');
my $objective_branch = substr($source, $objective_at, $grenade_at - $objective_at);
my $grenade_branch = substr($source, $grenade_at, $flag_at - $grenade_at);
my @objective_order = map { index($objective_branch, $_) } (
    'ktpParseCaptureMarkerEnvelope', 'ktpValidateObjectiveAttemptPayload',
    'ktpCaptureManifestAuthorizes', 'ktpObserveCaptureMarker',
    'doEvent_KTPObjectiveAttempt');
ok(!grep({ $_ < 0 } @objective_order) &&
   join(',', @objective_order) eq join(',', sort { $a <=> $b } @objective_order),
    'objective dispatch validates grammar, payload, and authorization before observation');
like($objective_branch,
    qr/if \(\$payload_error ne ""\).*?ktpRejectUnobservedCaptureMarker\(\s*"objective_attempt".*?ktpCaptureManifestAuthorizes/s,
    'authorized invalid objective payload is rejected without sequence observation');
my @grenade_order = map { index($grenade_branch, $_) } (
    'ktpParseCaptureMarkerEnvelope', 'ktpValidateGrenadeEntityPayload',
    'ktpCaptureManifestAuthorizes', 'ktpObserveCaptureMarker',
    'ktpParsePlayerIdentity', 'ktpResolvePlayerIdentity',
    'doEvent_KTPGrenadeEntity');
ok(!grep({ $_ < 0 } @grenade_order) &&
   join(',', @grenade_order) eq join(',', sort { $a <=> $b } @grenade_order),
    'grenade payload is fully authorized before durable owner correlation');
like($grenade_branch,
    qr/if \(\$payload_error ne ""\).*?ktpRejectUnobservedCaptureMarker\(\s*"grenade_entity".*?ktpCaptureManifestAuthorizes.*?\} elsif.*?ktpParsePlayerIdentity/s,
    'authorized invalid grenade payload is rejected before owner correlation');
like($source,
    qr/if \(\$p->\{event_type\} eq "grenade_entity".*?delete \$g_ktpCaptureSequences\{\$key\}.*?delete \$g_ktpAcceptedCaptureManifests\{\$key\}/s,
    'schema-22 reconciliation state lives through the final health type');

my $migration22 = slurp($MIGRATION22);
like($migration22, qr/CREATE TABLE IF NOT EXISTS ktp_objective_attempt_events/,
    'migration creates objective attempt ledger');
like($migration22, qr/UNIQUE KEY uk_objective_attempt_slot/,
    'schema enforces one immutable start and one terminal slot per attempt');
like($migration22, qr/UNIQUE KEY uk_objective_producer_sequence/,
    'objective producer event sequence is unique');
like($migration22, qr/CREATE TABLE IF NOT EXISTS ktp_grenade_entity_events/,
    'migration honestly names the grenade entity ledger');
like($migration22, qr/UNIQUE KEY uk_grenade_entity_kind/,
    'schema enforces one row per entity lifecycle kind');
like($migration22, qr/idx_grenade_owner/,
    'grenade owner analytics path is indexed');
like($migration22, qr/Private: never publish/,
    'grenade coordinates are explicitly private');
unlike($migration22, qr/\b(?:detonation|explosion)_?(?:cause|time|id|event|correlation)\b/i,
    'schema contains no detonation/explosion or damage-correlation column');
like($migration22, qr/information_schema\.STATISTICS/,
    'migration repairs missing indexes on rerun without vendor-only syntax');
like($migration22, qr/ERROR_022_objective_table_partial_or_incompatible/,
    'partial objective table fails with an actionable ledger-specific sentinel');
like($migration22, qr/ERROR_022_grenade_table_partial_or_incompatible/,
    'partial grenade table fails with an actionable ledger-specific sentinel');
like($migration22, qr/\@objective_column_count=20.*?\@grenade_column_count=21/s,
    'migration preflights every required column before index repair');
like($migration22,
    qr/\@objective_extra_required_columns=0.*?\@grenade_extra_required_columns=0/s,
    'migration rejects extra required columns that would break ledger inserts');
like($migration22,
    qr/GROUP_CONCAT\(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','\).*?MIN\(NON_UNIQUE\)=0.*?MIN\(NON_UNIQUE\)=1/s,
    'migration verifies exact ordered columns and uniqueness of named indexes');

done_testing();
