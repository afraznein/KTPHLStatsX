#!/usr/bin/perl
# ktpResolveShotTargetPlayerId turns the shot stream's engine userid into the
# durable player id stored in ktp_shot_events.tgt_player_id (migration 030).
#
# Why this exists: that column's whole purpose is to let a shot join
# ktp_damage_events on the VICTIM rather than only on (attacker, time). A
# wrong id is therefore worse than no id -- it does not merely lose the join,
# it silently credits one player's damage to another and makes the
# registration-failure rate read better than it is. Every case below is about
# the resolver refusing to guess.
#
# The real function is lifted out of hlstats.pl and executed, not mirrored, so
# a revert fails here instead of passing against a copy.
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

my $source = slurp($SRC);
$source =~ s/\r//g;

my ($fn) = $source =~ /^(sub ktpResolveShotTargetPlayerId\s*\{.*?^\})/ms
    or die "could not find sub ktpResolveShotTargetPlayerId in $SRC\n";

our %g_servers;
our $s_addr = '10.0.0.1:27015';
eval "no strict 'vars';\n$fn\n1;"
    or die "could not load ktpResolveShotTargetPlayerId: $@";

# Shape one live player set the way HLstats_Server keeps it: keyed
# "$userid/$uniqueid", each value an object carrying userid + playerid.
sub set_players {
    my (@rows) = @_;
    my %players;
    for my $r (@rows) {
        $players{ $r->{userid} . '/' . ($r->{uniqueid} // 'STEAM_X') } = $r;
    }
    $g_servers{$s_addr} = { srv_players => \%players };
}

set_players(
    { userid => 7,  uniqueid => 'STEAM_0:1:11', playerid => 4201 },
    { userid => 9,  uniqueid => 'STEAM_0:1:22', playerid => 4202 },
    { userid => 31, uniqueid => 'STEAM_0:1:33', playerid => 4203 },
);

is(ktpResolveShotTargetPlayerId(7), 4201, 'resolves a live userid to its player id');
is(ktpResolveShotTargetPlayerId(31), 4203, 'resolves the last entry too, so the scan does not stop early');
is(ktpResolveShotTargetPlayerId('9'), 4202, 'a numeric string userid resolves, since the wire is text');

is(ktpResolveShotTargetPlayerId(8), undef, 'an absent userid is undef, not a neighbouring player');
is(ktpResolveShotTargetPlayerId(undef), undef, 'undef userid is undef');

# The malformed-input cases below are only meaningful against a live set that
# CONTAINS a userid <= 0. hlstats.pl treats userid <= 0 as bot/world (the
# ignore_bots check at doEvent time reads exactly that), so such entries are
# ordinary. Without them every bad value trivially fails to match and the
# input guard looks redundant; with them, dropping the guard makes int('abc')
# and int('') collapse to 0 and resolve a garbage wire field to a real player
# id. That is the failure this is here to prevent, so the fixture has to make
# it reachable.
set_players(
    { userid => 0,  uniqueid => 'BOT:alpha',    playerid => 9001 },
    { userid => -1, uniqueid => 'BOT:bravo',    playerid => 9002 },
    { userid => 7,  uniqueid => 'STEAM_0:1:11', playerid => 4201 },
);
is(ktpResolveShotTargetPlayerId(''), undef, 'empty userid is undef, not the userid-0 entry');
is(ktpResolveShotTargetPlayerId('abc'), undef, 'non-numeric userid is undef, not the userid-0 entry');
is(ktpResolveShotTargetPlayerId('7abc'), undef, 'a partly-numeric userid is undef, not player 7');
is(ktpResolveShotTargetPlayerId(0), undef, 'userid 0 is undef -- 0 is the bot/world sentinel, not a player');
is(ktpResolveShotTargetPlayerId(-1), undef,
   'the producer -1 sentinel is undef, never a lookup, so a missing target cannot resolve to anyone');
is(ktpResolveShotTargetPlayerId(7), 4201, 'a real userid still resolves alongside bot/world entries');

set_players(
    { userid => 7,  uniqueid => 'STEAM_0:1:11', playerid => 4201 },
    { userid => 9,  uniqueid => 'STEAM_0:1:22', playerid => 4202 },
    { userid => 31, uniqueid => 'STEAM_0:1:33', playerid => 4203 },
);

# The reconnect case this resolver exists to refuse. Two live objects can carry
# the same userid across a reconnect; picking either one is a coin flip that
# writes a real-looking id for the wrong player.
set_players(
    { userid => 7, uniqueid => 'STEAM_0:1:11', playerid => 4201 },
    { userid => 7, uniqueid => 'STEAM_0:1:99', playerid => 5555 },
);
is(ktpResolveShotTargetPlayerId(7), undef,
   'two live players sharing a userid resolves to undef rather than guessing one');

# Same userid, same durable player id (the ordinary reconnect: a new live
# object for the same human). There is no ambiguity to refuse here.
set_players(
    { userid => 7, uniqueid => 'STEAM_0:1:11', playerid => 4201 },
    { userid => 7, uniqueid => 'STEAM_0:1:11b', playerid => 4201 },
);
is(ktpResolveShotTargetPlayerId(7), 4201,
   'duplicate entries agreeing on the player id still resolve, since nothing is ambiguous');

# Incomplete live objects must be skipped, not crashed on or half-read.
set_players(
    { userid => 7, uniqueid => 'STEAM_0:1:11' },                 # no playerid
    { userid => 9, uniqueid => 'STEAM_0:1:22', playerid => 4202 },
);
is(ktpResolveShotTargetPlayerId(7), undef, 'a live object with no player id is skipped');
is(ktpResolveShotTargetPlayerId(9), 4202, 'a skipped neighbour does not abort the scan');

set_players({ userid => 7, uniqueid => 'STEAM_0:1:11', playerid => 0 });
is(ktpResolveShotTargetPlayerId(7), undef, 'player id 0 is not a player and stays undef');

set_players({ userid => 7, uniqueid => 'STEAM_0:1:11', playerid => -3 });
is(ktpResolveShotTargetPlayerId(7), undef, 'a negative player id stays undef');

# No live set at all: a marker arriving before any player is tracked, or for a
# server we have no state for.
$g_servers{$s_addr} = {};
is(ktpResolveShotTargetPlayerId(7), undef, 'a server with no srv_players resolves to undef');
delete $g_servers{$s_addr};
is(ktpResolveShotTargetPlayerId(7), undef, 'an unknown server resolves to undef rather than dying');

# The resolver must not mutate the live set -- it runs on the ingest hot path
# for every shot, and HLstats_Player objects are shared with the reconnect
# bookkeeping.
set_players(
    { userid => 7, uniqueid => 'STEAM_0:1:11', playerid => 4201 },
    { userid => 9, uniqueid => 'STEAM_0:1:22', playerid => 4202 },
);
my $before = join('|', map { "$_=" . ($g_servers{$s_addr}{srv_players}{$_}{playerid} // 'undef') }
                  sort keys %{ $g_servers{$s_addr}{srv_players} });
ktpResolveShotTargetPlayerId($_) for (7, 9, 12, 0);
my $after = join('|', map { "$_=" . ($g_servers{$s_addr}{srv_players}{$_}{playerid} // 'undef') }
                 sort keys %{ $g_servers{$s_addr}{srv_players} });
is($after, $before, 'resolution is read-only: the live player set is unchanged');
is(scalar(keys %{ $g_servers{$s_addr}{srv_players} }), 2,
   'and a miss does not autovivify an entry for the userid it looked for');

done_testing();
