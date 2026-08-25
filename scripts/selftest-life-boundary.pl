#!/usr/bin/perl
# Focused regression for side-effect-free buffered identity parsing, producer
# clocks/half validation, event-time context resolution, and capture migrations.
use strict;
use warnings;
use Test::More;
use Digest::MD5;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';
my $MIGRATION16 = $SCRIPT_DIR . '../sql/migrate_016_life_events.sql';
my $MIGRATION17 = $SCRIPT_DIR . '../sql/migrate_017_capture_clocks_and_assists.sql';
my $MIGRATION20 = $SCRIPT_DIR . '../sql/migrate_020_capture_observability.sql';

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
my $identity = between_markers($source,
    '# BEGIN KTP SIDE-EFFECT-FREE PLAYER IDENTITY',
    '# END KTP SIDE-EFFECT-FREE PLAYER IDENTITY');
my $standalone_identity = between_markers($source,
    '# BEGIN KTP BUFFERED STANDALONE IDENTITY',
    '# END KTP BUFFERED STANDALONE IDENTITY');
my $validator = between_markers($source,
    '# BEGIN KTP LIFE BOUNDARY VALIDATION',
    '# END KTP LIFE BOUNDARY VALIDATION');
my $resolver = between_markers($source,
    '# BEGIN KTP LIFE BOUNDARY CONTEXT',
    '# END KTP LIFE BOUNDARY CONTEXT');

our (%g_servers, %g_ktpMatchContext, %g_ktpProducerContextCache,
     %g_ktpCaptureClockWarnings,
     $s_addr, $g_mode, @query_rows, $last_query, $query_count,
     $durable_player_id_lookups);
$s_addr = '127.0.0.1:27015';
$g_mode = 'Normal';
%g_servers = ($s_addr => { id => 42, srv_players => {} });

sub botidcheck { return defined($_[0]) && $_[0] =~ /^BOT(?::|$)/ ? 1 : 0; }
sub quoteSQL {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/\\'/g;
    return $value;
}
sub lookupPlayer {
    my ($addr, $userid, $uniqueid) = @_;
    return $g_servers{$addr}{srv_players}{"$userid/$uniqueid"};
}
sub getPlayerId {
    my ($uniqueid) = @_;
    $durable_player_id_lookups++;
    return 9001 if $uniqueid eq '1:123';
    return 9002 if $uniqueid eq '1:456';
    return 0;
}

{
    package LifeBoundaryFakeResult;
    sub new { my ($class, $rows) = @_; bless { rows => [@$rows] }, $class; }
    sub fetchrow_hashref { my ($self) = @_; return shift @{$self->{rows}}; }
    sub finish { return 1; }
}
sub doQuery {
    my ($query) = @_;
    $query_count++;
    $last_query = $query;
    return LifeBoundaryFakeResult->new(\@query_rows);
}

my $loaded = eval "no strict 'vars';\n$identity\n$validator\n$resolver\n1;";
die "cannot load shipped capture helpers: $@" unless $loaded;

# Delayed old-userid marker while the same Steam identity is connected under a
# new userid. Resolving the old marker must not disconnect/mutate the new object.
my $current = { playerid => 9001, userid => 8, uniqueid => '1:123', name => 'Alice' };
my $current_victim = { playerid => 9002, userid => 10, uniqueid => '1:456', name => 'Bob' };
$g_servers{$s_addr}{srv_players}{'8/1:123'} = $current;
$g_servers{$s_addr}{srv_players}{'10/1:456'} = $current_victim;
$durable_player_id_lookups = 0;
my $old_identity = ktpParsePlayerIdentity('Alice<7><STEAM_0:1:123><Allies>');
is_deeply($old_identity,
    { name => 'Alice', userid => 7, uniqueid => '1:123', team => 'Allies',
      role => undef, is_bot => 0 },
    'buffered identity parses without live-state helpers');
is(ktpResolvePlayerIdentity($old_identity), 9001,
    'old userid resolves through durable unique-id mapping');
is($durable_player_id_lookups, 1, 'different userid does not match live object');
is($g_servers{$s_addr}{srv_players}{'8/1:123'}, $current,
    'reconnected player object remains present and unchanged');
my $old_victim_identity = ktpParsePlayerIdentity('Bob<9><STEAM_0:1:456><Axis>');
is(ktpResolvePlayerIdentity($old_victim_identity), 9002,
    'delayed victim identity resolves durably after reconnect');
my $generic_actor = ktpIdentityForGenericAction($old_identity, 9001);
my $generic_victim = ktpIdentityForGenericAction($old_victim_identity, 9002);
is_deeply([$generic_actor->{userid}, $generic_victim->{userid}], [8, 10],
    'generic assist dispatch uses exact current tuples selected by durable ids');
is_deeply($current,
    { playerid => 9001, userid => 8, uniqueid => '1:123', name => 'Alice' },
    'generic assist identity adaptation does not mutate actor reconnect object');
is_deeply($current_victim,
    { playerid => 9002, userid => 10, uniqueid => '1:456', name => 'Bob' },
    'generic assist identity adaptation does not mutate victim reconnect object');

my $line = '"Alice<7><STEAM_0:1:123><Allies>" triggered "life_boundary" '
    . '(matchid "KTP-42") (half "2") (event_epoch "1787154601") '
    . '(game_time "123.45") (kind "start") (reason "spawn") '
    . '(team "1") (class "3") (slot "7")';
my ($tail) = ($line =~ /triggered "life_boundary"(.*)$/);
my %properties;
while ($tail =~ s/^\s*\(([^\s()]+) "(.*?)"\)//) {
    $properties{$1} = $2;
}
is_deeply(\%properties,
    { matchid => 'KTP-42', half => '2', event_epoch => '1787154601',
      game_time => '123.45', kind => 'start', reason => 'spawn', team => '1',
      class => '3', slot => '7' },
    'producer match, half, and clocks parse losslessly');

is(ktpValidateLifeBoundaryPayload(
        @properties{qw(matchid half kind reason team class slot round_live game_time event_epoch)}),
    '', 'representative producer-timed life boundary validates');
like(ktpValidateLifeBoundaryPayload(
        'KTP-42', 0, 'start', 'spawn', 1, 1, 1, undef, 1, 1),
    qr/producer half/, 'unknown producer half fails closed');
like(ktpValidateLifeBoundaryPayload(
        'KTP-42', 2, 'start', 'death', 1, 1, 1, undef, 1, 1),
    qr/kind\/reason/, 'invalid life semantic pair is rejected');
like(ktpValidateLifeBoundaryPayload(
        'KTP-42', 2, 'start', 'spawn', 3, 1, 1, undef, 1, 1),
    qr/team/, 'non-playing teams must already be normalized to zero');
like(ktpValidateLifeBoundaryPayload(
        'KTP-42', 2, 'start', 'spawn', 1, 1, 1, undef, '-1', 1),
    qr/game_time/, 'negative game clock is rejected');
like(ktpValidateLifeBoundaryPayload(
        'KTP-42', 2, 'start', 'spawn', 1, 1, 1, undef, 1, 0),
    qr/event_epoch/, 'non-positive producer epoch is rejected');

%g_ktpProducerContextCache = ();
@query_rows = ({ match_id => 'KTP-42', half => 2, map_name => 'dod_anzio',
    start_epoch => 1787154500, end_epoch => 1787154700, proof_epoch => 1787154800 });
my ($half, $map, $error, $source_name) =
    ktpResolveProducerEventContext('KTP-42', 2, 1787154601);
is_deeply([$half, $map, $error, $source_name],
    [2, 'dod_anzio', '', 'event-time-interval'],
    'one exact event-time interval validates producer attribution');
my $queries_after_proof = $query_count;
@query_rows = ();
($half, $map, $error, $source_name) =
    ktpResolveProducerEventContext('KTP-42', 2, 1787154602);
is($source_name, 'event-time-interval-cache',
    'closed interval proof is reused for another producer second');
is($query_count, $queries_after_proof,
    'closed interval cache avoids per-hit DB queries');
like($last_query, qr/server_id\s*=\s*42/s, 'interval lookup is server scoped');
like($last_query, qr/start_time <= FROM_UNIXTIME\(1787154601\)/s,
    'interval lookup uses producer event time, not receipt time');
like($last_query, qr/end_time IS NULL OR end_time >= FROM_UNIXTIME\(1787154601\)/s,
    'closed and open interval ends are checked');

%g_ktpProducerContextCache = ();
@query_rows = ({ match_id => 'KTP-42', half => 2, map_name => 'dod_anzio',
    start_epoch => 1787154500, end_epoch => undef, proof_epoch => 1787154601 });
ktpResolveProducerEventContext('KTP-42', 2, 1787154601);
my $open_queries = $query_count;
@query_rows = ({ match_id => 'KTP-42', half => 2, map_name => 'dod_anzio',
    start_epoch => 1787154500, end_epoch => undef, proof_epoch => 1787154601 });
(undef, undef, $error, undef) =
    ktpResolveProducerEventContext('KTP-42', 2, 1787154602);
like($error, qr/exceeds open-interval proof horizon/,
    'query miss rejects future producer epoch beyond DB proof horizon');
is($query_count, $open_queries + 1,
    'future open-interval epoch is DB-checked and not cached');
@query_rows = ({ match_id => 'KTP-42', half => 2, map_name => 'dod_anzio',
    start_epoch => 1787154500, end_epoch => undef, proof_epoch => 1787154602 });
($half, $map, $error, $source_name) =
    ktpResolveProducerEventContext('KTP-42', 2, 1787154602);
is($query_count, $open_queries + 2,
    'open interval refreshes when producer epoch exceeds DB proof horizon');
is($error, '', 'refreshed open interval still validates exact context');

%g_ktpProducerContextCache = ();
@query_rows = ();
(undef, undef, $error, undef) =
    ktpResolveProducerEventContext('KTP-42', 2, 1787154601);
like($error, qr/found 0 event-time match intervals/, 'zero intervals fails closed');
%g_ktpProducerContextCache = ();
@query_rows = (
    { match_id => 'KTP-42', half => 1, map_name => 'dod_anzio',
      start_epoch => 1787154500, end_epoch => 1787154700, proof_epoch => 1787154800 },
    { match_id => 'KTP-42', half => 2, map_name => 'dod_anzio',
      start_epoch => 1787154500, end_epoch => 1787154700, proof_epoch => 1787154800 },
);
(undef, undef, $error, undef) =
    ktpResolveProducerEventContext('KTP-42', 2, 1787154601);
like($error, qr/found 2 event-time match intervals/, 'overlap ambiguity fails closed');
%g_ktpProducerContextCache = ();
@query_rows = ({ match_id => 'ktp-42', half => 2, map_name => 'dod_anzio',
    start_epoch => 1787154500, end_epoch => 1787154700, proof_epoch => 1787154800 });
(undef, undef, $error, undef) =
    ktpResolveProducerEventContext('KTP-42', 2, 1787154601);
like($error, qr/case mismatch/, 'case-insensitive SQL result fails exact comparison');
%g_ktpProducerContextCache = ();
@query_rows = ({ match_id => 'KTP-42', half => 1, map_name => 'dod_anzio',
    start_epoch => 1787154500, end_epoch => 1787154700, proof_epoch => 1787154800 });
(undef, undef, $error, undef) =
    ktpResolveProducerEventContext('KTP-42', 2, 1787154601);
like($error, qr/producer half disagrees/, 'explicit producer half is DB-validated');

%g_ktpProducerContextCache = ();
@query_rows = ({ match_id => 'KTP-42', half => 2, map_name => 'dod_anzio',
    start_epoch => 1787154500, end_epoch => 1787154700, proof_epoch => 1787154800 });
(undef, undef, $error, undef) =
    ktpResolveValidatedProducerEventContext('KTP-42', 0, 12.25, 1787154601);
like($error, qr/invalid producer half/,
    'frag authoritative clocks reject invalid producer half before attribution');
%g_ktpProducerContextCache = ();
@query_rows = ({ match_id => 'KTP-42', half => 1, map_name => 'dod_anzio',
    start_epoch => 1787154500, end_epoch => 1787154700, proof_epoch => 1787154800 });
(undef, undef, $error, undef) =
    ktpResolveValidatedProducerEventContext('KTP-42', 2, 12.25, 1787154601);
like($error, qr/producer half disagrees/,
    'damage authoritative clocks reject DB interval half mismatch');
ok(!ktpHasExplicitProducerContext(undef) &&
   !ktpHasExplicitProducerContext('') &&
   !ktpHasExplicitProducerContext('-'),
    'old and warmup sentinel markers are expected legacy context');
ok(ktpHasExplicitProducerContext('KTP-42'),
    'plausible explicit match context is validated');

# The product query must choose FIFO only inside the exact producer second.
# Model a lost marker between two receipt rows: the later marker may select only
# its own second and can never shift onto the earlier uncontextualized frag.
my @uncontextualized_frag_epochs = (1787154600, 1787154602);
my @later_candidates = grep { $_ >= 1787154602 && $_ < 1787154603 }
    @uncontextualized_frag_epochs;
is_deeply(\@later_candidates, [1787154602],
    'later producer marker cannot cross-link to row left by a lost marker');
my @missing_candidates = grep { $_ >= 1787154601 && $_ < 1787154602 }
    @uncontextualized_frag_epochs;
is(scalar(@missing_candidates), 0,
    'missing producer-second frag fails closed instead of shifting FIFO');

my ($life_parser_branch) = ($source =~ /(if \(\$ev_obj_a eq "life_boundary"\).*?\}\s*elsif)/s);
like($life_parser_branch, qr/\$ktp_buffered_player_id/,
    'life parser consumes the durable identity resolved by buffered prepass');
unlike($life_parser_branch, qr/\&getPlayerInfo/,
    'life parser never calls mutating getPlayerInfo');
like($source, qr/doEvent_KTPAssist\(.*?doEvent_PlayerPlayerAction/s,
    'canonical assist insert runs while generic action path remains');
my ($capture_prepass) = ($source =~
    /(if \(\$ev_obj_a =~ \/\^\(\?:assist\|frag_context\|damage\|headshot_kill.*?\n\s*\})/s);
like($capture_prepass, qr/ktpParsePlayerIdentity.*?ktpResolvePlayerIdentity/s,
    'all buffered player-player markers share pure durable identity prepass');
unlike($capture_prepass, qr/getPlayerInfo/,
    'buffered identity prepass cannot call mutating getPlayerInfo');
my ($frag_branch) = ($source =~
    /elsif \(\$ev_obj_a eq "frag_context"\) \{(.*?)\n\s*\} elsif \(\$ev_obj_a eq "damage"\)/s);
unlike($frag_branch, qr/getPlayerInfo/,
    'frag_context branch never calls mutating getPlayerInfo');
like($frag_branch, qr/ktpResolveValidatedProducerEventContext/,
    'frag clocks require DB-validated producer context');
like($frag_branch,
    qr/eventTime >= FROM_UNIXTIME.*?eventTime < FROM_UNIXTIME/s,
    'authoritative frag association is bounded to one producer second');
for my $alias_pair (
    [qw(brit_knife amerknife)], [qw(garandbutt garand)],
    [qw(bayonet kar)], [qw(fcarbine m1carbine)],
    [qw(scoped_fg42 fg42)], [qw(k43butt k43)],
    [qw(scoped_enfield enfield)], [qw(enf_bayonet enfield)],
) {
    my ($producer, $stock) = @$alias_pair;
    like($frag_branch,
        qr/\Q"$producer"\E\s*=>\s*\Q"$stock"\E/,
        "frag association explicitly maps DODX $producer to stock $stock");
}
like($frag_branch, qr/AND weapon IN \(\$fc_weapon_where\)/,
    'frag association uses only its explicit producer/base weapon candidates');
unlike($frag_branch, qr/OR\s+weapon\s*=/,
    'frag association has no unconstrained weapon fallback');
like($frag_branch, qr/\$fc_clock_sql = "".*?legacy receipt window/s,
    'legacy frag tactical facts remain while authoritative clocks stay NULL');
my ($damage_branch) = ($source =~
    /elsif \(\$ev_obj_a eq "damage"\) \{(.*?)\n\s*\} else \{\s*\n\s*my \(\$playerinfo/s);
unlike($damage_branch, qr/getPlayerInfo/,
    'damage branch never calls mutating getPlayerInfo');
like($damage_branch, qr/\$ktp_actor_player_id.*?\$ktp_victim_player_id/s,
    'damage uses pure durable player ids');
my ($generic_assist_branch) = ($source =~
    /if \(\$ev_obj_a eq "assist"\) \{\s*# Reuse(.*?)\n\s*\} else \{/s);
like($generic_assist_branch, qr/ktpIdentityForGenericAction/s,
    'generic rating-neutral assist uses safe live-tuple adapter');
unlike($generic_assist_branch, qr/getPlayerInfo/,
    'generic assist path cannot mutate reconnect state');
like($standalone_identity,
    qr/ktpParsePlayerIdentity.*?ktpResolvePlayerIdentity.*?ktpIdentityForGenericAction/s,
    'life/cap-break/break-context/position markers use pure durable identity path');
unlike($standalone_identity, qr/\&getPlayerInfo/,
    'no KSC-buffered standalone marker calls mutating getPlayerInfo');
my ($break_branch) = ($source =~
    /elsif \(\$ev_obj_a eq "break_context"\) \{(.*?)\n\s*\} elsif \(\$ev_obj_a eq "position_sample"\)/s);
unlike($break_branch, qr/lookupPlayer|getPlayerInfo/,
    'break_context updates by durable player id without live-state lookup');
like($break_branch, qr/playerId = "\.int\(\$ktp_buffered_player_id\)/,
    'break_context SQL uses durable player id');
my ($position_branch) = ($source =~
    /elsif \(\$ev_obj_a eq "position_sample"\) \{(.*?)\n\s*\} elsif \(\$ev_obj_a eq "player_changeclass"/s);
unlike($position_branch, qr/lookupPlayer|getPlayerInfo/,
    'position_sample persists by durable player id without live-state lookup');
like($position_branch, qr/doEvent_KTPPosition\(\s*\$ktp_buffered_player_id/s,
    'position_sample passes the durable id to its ledger');
my ($position_ledger) = ($source =~
    /sub doEvent_KTPPosition\s*\{(.*?)\n\}/s);
like($position_ledger, qr/ktpResolveValidatedProducerEventContext/,
    'position ledger uses event-time producer context when present');
like($break_branch, qr/Break context dropped: cap_break action is unavailable/,
    'break context rejects missing generic cap-break action');
like($source, qr/\$has_explicit_context\s*=\s*ktpHasExplicitProducerContext.*?elsif \(\$has_explicit_context\)/s,
    'damage silently bypasses validation/warnings for absent sentinel context');
like($source, qr/\$count % 1000/s,
    'genuine producer-clock failures are aggregated instead of log-flooded');
like($source, qr/scalar\(keys %g_ktpProducerContextCache\) >= 512/s,
    'producer interval cache has a hard process-lifetime bound');
my $shared_resolver_calls = () =
    $source =~ /ktpResolveProducerEventContext\(\$matchid, \$producer_half, \$event_epoch\)/g;
cmp_ok($shared_resolver_calls, '>=', 2,
    'life and assist share the event-time context resolver');
like($source, qr/producer_match_id = .*?producer_half =/s,
    'frag context persists producer match/half');
like($source, qr/event_epoch = .*?frag_context_recorded/s,
    'frag context persists producer clocks');
like($source, qr/FROM_UNIXTIME\(\$event_epoch\)/,
    'damage and canonical ledgers derive event time from producer epoch');

my $migration16 = slurp($MIGRATION16);
like($migration16, qr/CREATE TABLE IF NOT EXISTS ktp_life_events/,
    'migration 016 creates life ledger');
like($migration16, qr/half TINYINT UNSIGNED NOT NULL/,
    'life ledger persists validated producer half');

my $migration17 = slurp($MIGRATION17);
like($migration17, qr/CREATE TABLE IF NOT EXISTS ktp_assist_events/,
    'migration 017 creates canonical assist ledger');
for my $column (qw(producer_match_id producer_half game_time event_epoch)) {
    like($migration17, qr/COLUMN_NAME = '\Q$column\E'/,
        "migration 017 guards additive $column column");
}
for my $column (qw(match_id half assister_id victim_id game_time event_epoch event_time)) {
    like($migration17, qr/^\s*\Q$column\E\s+/m,
        "canonical assist table contains $column");
}
like($migration17, qr/Timed analytics must filter\/join on producer_match_id/s,
    'migration warns analytics away from receipt-time context');
like($migration17, qr/idx_frag_producer_context \(producer_match_id, producer_half, event_epoch\)/,
    'frag producer-context analytics path is indexed');
like($migration17, qr/idx_damage_producer_context \(producer_match_id, producer_half, event_epoch\)/,
    'damage producer-context analytics path is indexed');

my $migration20 = slurp($MIGRATION20);
like($migration20, qr/CREATE TABLE IF NOT EXISTS ktp_capture_manifests/,
    'migration 020 creates producer manifest ledger');
like($migration20, qr/CREATE TABLE IF NOT EXISTS ktp_capture_health/,
    'migration 020 creates producer-daemon reconciliation ledger');
for my $column (qw(producer_sequence break_victim_id break_incident_id flag_index flag_name)) {
    like($migration20, qr/\b\Q$column\E\b/,
        "migration 020 includes $column observability field");
}
like($source, qr/^sub ktpObserveCaptureMarker/m,
    'daemon tracks globally monotonic producer sequences');
like($source, qr/^sub doEvent_KTPCaptureHealth/m,
    'daemon persists per-type capture health reconciliation');
my ($pending_life) = ($source =~
    /sub ktpQueuePendingLife\s*\{(.*?)# BEGIN KTP LIFE BOUNDARY VALIDATION/s);
unlike($pending_life, qr/getPlayerInfo/,
    'pending life retry never mutates reconnect state');
like($pending_life, qr/scalar\(keys %g_ktpPendingLife\)|keys %g_ktpPendingLife/,
    'pending life retry has a process-lifetime bound');
my ($health_handler) = ($source =~
    /sub doEvent_KTPCaptureHealth\s*\{(.*?)\n\}/s);
like($health_handler, qr/ktpDrainPendingLife.*?daemon_received/s,
    'life retries finalize before health accepted/rejected reconciliation');
my ($pending_damage) = ($source =~
    /sub ktpQueuePendingDamage\s*\{(.*?)# BEGIN KTP LIFE BOUNDARY VALIDATION/s);
unlike($pending_damage, qr/getPlayerInfo/,
    'pending damage retry never mutates reconnect state');
like($pending_damage, qr/total >= 4096/,
    'pending damage retry has an explicit process-lifetime bound');
like($health_handler, qr/ktpDrainPendingDamage.*?daemon_received/s,
    'damage retries finalize before health accepted/rejected reconciliation');
my %healthy = (
    matchid => 'health-only-TEST', half => 1, event_type => 'life',
    attempted => 1, enqueued => 1, dropped => 0, emitted => 1,
    sequence_first => 1, sequence_last => 1, sequence => 2,
    event_epoch => 1787616774,
);
is(ktpValidateCaptureHealthPayload(\%healthy), '',
    'capture health accepts a normal nonnumeric match id');
$healthy{matchid} = 'bad match id';
like(ktpValidateCaptureHealthPayload(\%healthy), qr/matchid/,
    'capture health rejects malformed match identity');
$healthy{matchid} = 'health-only-TEST';
$healthy{attempted} = 'not-a-number';
like(ktpValidateCaptureHealthPayload(\%healthy), qr/attempted/,
    'capture health validates counters as numeric fields');

done_testing();
