#!/usr/bin/perl
# Regression for DoD 1.3 capture credit: both completion codes, the branch each
# one takes, and what lands in ktp_flag_captures.
#
# WHY THIS RUNS THE SHIPPED BLOCKS INSTEAD OF MIRRORING THEM. The defect being
# guarded is a handler quietly stopping: on 2026-08-14 dod_capture_area was
# diverted and credit went silent with nothing erroring, and dod_control_point
# had no handler at all while ktp_flag_captures still filled up from the other
# code. Both failures leave every count plausible. A harness that built its own
# fixtures and never reached the real dispatch would stay green over a dead
# path, so the dispatch and the credit sub are lifted out of hlstats.pl by
# marker and executed.
#
# Nothing here asserts a total. The 2026-08-14 regression was invisible in
# totals for weeks and only showed as flag names that had stopped appearing, so
# these assert per-event credit and branch structure instead.
#
#   perl scripts/selftest-capture-credit.pl        # exit 0 = pass
use strict;
use warnings;
use Test::More;

my $SCRIPT_DIR = $0;
$SCRIPT_DIR =~ s{[^/\\]+$}{};
my $SRC = $SCRIPT_DIR . 'hlstats.pl';

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
my $dispatch = between_markers($source,
    '# BEGIN KTP CAPTURE DISPATCH',
    '# END KTP CAPTURE DISPATCH');
my $credit = between_markers($source,
    '# BEGIN KTP FLAG CAPTURE CREDIT',
    '# END KTP FLAG CAPTURE CREDIT');

# Fixtures are raw log lines run through the daemon's own prototype pattern, so
# a parse change reaches this file rather than leaving it asserting on a shape
# the daemon no longer produces.
sub shipped_prototype_regex {
    my @lines = split(/\n/, $source);
    for my $i (1 .. $#lines) {
        next unless $lines[$i] =~ /^\s*#\s*Prototype: "player" verb "obj_a"\[properties\]/;
        my ($pattern) = ($lines[$i - 1] =~ m{\$s_output =~ /(.+)/\)});
        die "prototype line found but no pattern on it" unless defined($pattern);
        return qr/$pattern/;
    }
    die 'missing prototype: "player" verb "obj_a"[properties]';
}
my $PROTOTYPE = shipped_prototype_regex();

our (%g_servers, %g_ktpMatchContext, $s_addr,
     $playerinfo, $ev_obj_a, $ev_properties, %ev_properties, $ev_type, $ev_status,
     @inserts, @actions, %roster);
$s_addr = '127.0.0.1:27015';
%g_servers = ($s_addr => { id => 42 });

sub quoteSQL {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/\\'/g;
    return $value;
}
sub execNonQuery { push(@inserts, $_[0]); return 1; }
sub lookupPlayer {
    my ($addr, $userid, $uniqueid) = @_;
    return $roster{"$addr/$userid/$uniqueid"};
}
sub doEvent_PlayerAction {
    my ($userid, $uniqueid, $action) = @_;
    push(@actions, { userid => $userid, uniqueid => $uniqueid, action => $action });
    return "Action recorded";
}

my $credit_loaded = eval "no strict 'vars';\n$credit\n1;";
die "cannot load shipped flag-capture credit sub: $@" unless $credit_loaded;

%roster = (
    "$s_addr/7/1:123"  => { playerid => 9001 },
    "$s_addr/11/1:456" => { playerid => 9002 },
);

# Runs one raw log line through the shipped dispatch and reports what it did.
sub dispatch_line {
    my ($line, %opt) = @_;
    my ($ev_player, $ev_verb, $obj_a, $tail) = ($line =~ $PROTOTYPE);
    die "fixture did not match the shipped prototype: $line" unless defined($ev_verb);
    die "fixture is not a 'triggered a' line: $line" unless $ev_verb eq 'triggered a';

    my ($name, $userid, $steamid, $team) =
        ($ev_player =~ /^(.+?)<(\d+)><STEAM_0:(\d:\d+)><(.*?)>$/);
    die "fixture identity is unparsable: $ev_player" unless defined($userid);

    $playerinfo = $opt{no_playerinfo} ? undef
        : { userid => $userid, uniqueid => $steamid, team => $team, name => $name };
    $ev_obj_a = $obj_a;
    $ev_properties = $tail;
    %ev_properties = ();
    $ev_type = undef;
    $ev_status = undef;
    @inserts = ();
    @actions = ();

    my $ran = eval "no strict 'vars';\n$dispatch\n1;";
    die "cannot run shipped capture dispatch: $@" unless $ran;

    return {
        ev_type => $ev_type,
        ev_status => $ev_status,
        rows => [map { parse_capture_row($_) } @inserts],
        inserts => [@inserts],
        actions => [@actions],
    };
}

# Asserting on the tuple rather than splitting it also pins the column order the
# INSERT writes; a reordered VALUES list fails here instead of transposing
# player_id and team into columns that both accept it.
sub parse_capture_row {
    my ($sql) = @_;
    return { table => 'other' } unless $sql =~ /INSERT INTO ktp_flag_captures/;
    my ($server_id, $match_id, $half, $player_id, $team, $flag) = ($sql =~
        m{VALUES\s*\(\s*(\d+),\s*(NULL|'[^']*'),\s*(\d+),\s*(\d+),\s*(NULL|'[^']*'),\s*(NULL|'[^']*'),\s*NOW\(\)\s*\)}s);
    die "ktp_flag_captures INSERT does not match the expected tuple: $sql"
        unless defined($player_id);
    my $unquote = sub { $_[0] eq 'NULL' ? undef : do { my $v = $_[0]; $v =~ s/^'|'$//g; $v } };
    return {
        table => 'ktp_flag_captures',
        server_id => $server_id,
        match_id => $unquote->($match_id),
        half => $half,
        player_id => $player_id,
        team => $unquote->($team),
        flag_name => $unquote->($flag),
    };
}

# --- dod_capture_area: the multi-capper code ---------------------------------
my $area = dispatch_line(
    '"Alice<7><STEAM_0:1:123><Allies>" triggered a "dod_capture_area" - "flash"');
is($area->{ev_type}, 609, 'dod_capture_area takes the flag-capture branch');
is(scalar(@{$area->{rows}}), 1, 'dod_capture_area writes one capture row');
is($area->{rows}[0]{table}, 'ktp_flag_captures', 'and writes it to ktp_flag_captures');
is($area->{rows}[0]{player_id}, 9001, 'credited to the durable player id, not the userid');
is($area->{rows}[0]{team}, 'Allies', 'carrying the capping team off the line');
is($area->{rows}[0]{flag_name}, 'flash', 'and the point name parsed off the tail');
is($area->{rows}[0]{server_id}, 42, 'against the reporting server');

# The 2026-08-14 diversion is now the shipped design for this code: the generic
# PlayerAction row is deliberately not written, and the redundant Team line is
# what the discarded half of that decision refers to.
is(scalar(@{$area->{actions}}), 0,
    'dod_capture_area writes no PlayerAction row -- it is diverted by design');

# --- dod_control_point: the single-capper code -------------------------------
my $point = dispatch_line(
    '"Alice<7><STEAM_0:1:123><Allies>" triggered a "dod_control_point" - "mountain house"');
is($point->{ev_type}, 11, 'dod_control_point stays on the generic action branch');
is(scalar(@{$point->{rows}}), 1, 'dod_control_point writes one capture row');
is($point->{rows}[0]{player_id}, 9001, 'credited to the durable player id');
is($point->{rows}[0]{team}, 'Allies', 'carrying the capping team');
is($point->{rows}[0]{flag_name}, 'mountain house',
    'and a point name containing a space survives the tail parse');

# `caps` is sourced from the PlayerAction row for this code, so crediting
# ktp_flag_captures at the cost of that row is the 2026-08-14 failure again.
is(scalar(@{$point->{actions}}), 1, 'dod_control_point still writes its PlayerAction row');
is($point->{actions}[0]{action}, 'dod_control_point', 'under its own action code');
is($point->{actions}[0]{uniqueid}, '1:123', 'for the capping player');

# --- exactly one branch per line ---------------------------------------------
isnt($area->{ev_type}, $point->{ev_type},
    'the two codes are told apart -- one line cannot take both branches');
is(scalar(grep { $_->{table} eq 'ktp_flag_captures' } @{$area->{rows}}), 1,
    'dod_capture_area credits once, not once per branch');
is(scalar(grep { $_->{table} eq 'ktp_flag_captures' } @{$point->{rows}}), 1,
    'dod_control_point credits once, not once per branch');

# Exclusivity is by construction, not by the fixtures happening to differ.
my ($area_branch) = ($source =~
    /if \(\$playerinfo && \$ev_obj_a eq "dod_capture_area"\) \{(.*?)\n\t+\} else \{/s);
ok(defined($area_branch), 'the dod_capture_area test is present');
unlike($area_branch, qr/dod_control_point/,
    'dod_control_point is not reachable from inside the dod_capture_area branch');
like($source, qr/\} else \{.*?if \(\$ev_obj_a eq "dod_control_point"\) \{/s,
    'dod_control_point sits in the else of the dod_capture_area test');

# --- the control: a non-capture line on the same branch ----------------------
# Without this every assertion above would also pass against a handler that
# credited every "triggered a" line it saw.
my $other = dispatch_line(
    '"Alice<7><STEAM_0:1:123><Allies>" triggered a "dod_object_destroyed" - "flash"');
is(scalar(@{$other->{rows}}), 0, 'an unrelated action writes no capture row');
is(scalar(@{$other->{actions}}), 1, 'but still writes its PlayerAction row');
is($other->{actions}[0]{action}, 'dod_object_destroyed', 'under its own action code');

# --- credit is per event, not per line shape ---------------------------------
my $other_capper = dispatch_line(
    '"Bob<11><STEAM_0:1:456><Axis>" triggered a "dod_capture_area" - "flash"');
is($other_capper->{rows}[0]{player_id}, 9002,
    'a second capper on the same point is credited to himself');
is($other_capper->{rows}[0]{team}, 'Axis', 'with his own team');
isnt($other_capper->{rows}[0]{player_id}, $area->{rows}[0]{player_id},
    'two cappers do not collapse onto one credit');

# Both codes carry the same fixture team above, so without an opposing team here
# a hardcoded side would still satisfy every assertion on this branch.
my $other_point = dispatch_line(
    '"Bob<11><STEAM_0:1:456><Axis>" triggered a "dod_control_point" - "arch"');
is($other_point->{rows}[0]{player_id}, 9002, 'the control-point branch credits its own capper');
is($other_point->{rows}[0]{team}, 'Axis', 'and reads the team off the line, not a fixed side');
is($other_point->{actions}[0]{uniqueid}, '1:456', 'his PlayerAction row is his own');

# --- a live match tags the credit --------------------------------------------
%g_ktpMatchContext = ($s_addr => { match_id => 'ktp-2026-09-09-1', half_num => 2, round_live => 1 });
my $live = dispatch_line(
    '"Alice<7><STEAM_0:1:123><Allies>" triggered a "dod_control_point" - "arch"');
is($live->{rows}[0]{match_id}, 'ktp-2026-09-09-1', 'a live round tags the credit with its match');
is($live->{rows}[0]{half}, 2, 'and its half');
$g_ktpMatchContext{$s_addr}{round_live} = 0;
my $warmup = dispatch_line(
    '"Alice<7><STEAM_0:1:123><Allies>" triggered a "dod_control_point" - "arch"');
is($warmup->{rows}[0]{match_id}, undef, 'a dead round leaves the match unattributed');
%g_ktpMatchContext = ();

# --- malformed and unknown inputs --------------------------------------------
my $no_point = dispatch_line(
    '"Alice<7><STEAM_0:1:123><Allies>" triggered a "dod_control_point"');
is(scalar(@{$no_point->{rows}}), 1, 'a capture line missing its point name still credits');
is($no_point->{rows}[0]{flag_name}, undef, 'with the point name left unrecorded, not blank');
is(scalar(@{$no_point->{actions}}), 1, 'and its PlayerAction row is unaffected');

my $unknown = dispatch_line(
    '"Ghost<7><STEAM_0:1:999><Allies>" triggered a "dod_capture_area" - "flash"');
is(scalar(@{$unknown->{rows}}), 0, 'a player with no durable id credits nobody');

my $unknown_point = dispatch_line(
    '"Ghost<7><STEAM_0:1:999><Allies>" triggered a "dod_control_point" - "flash"');
is(scalar(@{$unknown_point->{rows}}), 0, 'the same on the control-point branch');
is(scalar(@{$unknown_point->{actions}}), 1,
    'and the PlayerAction row survives an unresolvable capper');

my $no_info = dispatch_line(
    '"Alice<7><STEAM_0:1:123><Allies>" triggered a "dod_capture_area" - "flash"',
    no_playerinfo => 1);
is(scalar(@{$no_info->{rows}}), 0, 'no player info credits nobody');
is(scalar(@{$no_info->{actions}}), 0, 'and writes no action either');

# --- the credit sub refuses what it cannot attribute -------------------------
@inserts = ();
is(doEvent_KTPFlagCapture(undef, 'Allies', 'flash'), 0, 'an undefined player is refused');
is(scalar(@inserts), 0, 'and nothing is written');

done_testing();
