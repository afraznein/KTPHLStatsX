#!/usr/bin/perl
# HLstatsX Community Edition - Real-time player and clan rankings and statistics
# Copyleft (L) 2008-20XX Nicholas Hastings (nshastings@gmail.com)
# http://www.hlxcommunity.com
#
# HLstatsX Community Edition is a continuation of 
# ELstatsNEO - Real-time player and clan rankings and statistics
# Copyleft (L) 2008-20XX Malte Bayer (steam@neo-soft.org)
# http://ovrsized.neo-soft.org/
# 
# ELstatsNEO is an very improved & enhanced - so called Ultra-Humongus Edition of HLstatsX
# HLstatsX - Real-time player and clan rankings and statistics for Half-Life 2
# http://www.hlstatsx.com/
# Copyright (C) 2005-2007 Tobias Oetzel (Tobi@hlstatsx.com)
#
# HLstatsX is an enhanced version of HLstats made by Simon Garner
# HLstats - Real-time player and clan rankings and statistics for Half-Life
# http://sourceforge.net/projects/hlstats/
# Copyright (C) 2001  Simon Garner
#             
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
# 
# For support and installation notes visit http://www.hlxcommunity.com

use strict;
no strict 'vars';

$SIG{HUP} = 'HUP_handler';
$SIG{INT} = 'INT_handler';  # unix
$SIG{INT2} = 'INT_handler';  # windows

##
## Settings
##

# $opt_configfile - Absolute path and filename of configuration file.
$opt_configfile = "./hlstats.conf";

# $opt_libdir - Directory to look in for local required files
#               (our *.plib, *.pm files).
$opt_libdir = "./";


##
##
################################################################################
## No need to edit below this line
##

use Getopt::Long;
use Time::Local;
use IO::Socket;
use IO::Select;
use DBI;
use Digest::MD5;
use Encode;
use Socket qw(sockaddr_in inet_ntoa SO_RCVBUF);
use bytes;

require "$opt_libdir/ConfigReaderSimple.pm";
require "$opt_libdir/TRcon.pm";
require "$opt_libdir/BASTARDrcon.pm";
require "$opt_libdir/HLstats_Server.pm";
require "$opt_libdir/HLstats_Player.pm";
require "$opt_libdir/HLstats_Game.pm";
do "$opt_libdir/HLstats_GameConstants.plib";
do "$opt_libdir/HLstats.plib";
do "$opt_libdir/HLstats_EventHandlers.plib";

$|=1;
Getopt::Long::Configure ("bundling");

$last_trend_timestamp = 0;

binmode STDIN, ":utf8";
binmode STDOUT, ":utf8";

##
## Functions
##

sub lookupPlayer
{
	my ($saddr, $id, $uniqueid) = @_;
	if (defined($g_servers{$saddr}->{"srv_players"}->{"$id/$uniqueid"}))
	{
		return $g_servers{$saddr}->{"srv_players"}->{"$id/$uniqueid"};
	}
	return undef;
}

sub removePlayer
{
	my ($saddr, $id, $uniqueid, $dontUpdateCount) = @_;
	my $deleteplayer = 0;
	if(defined($g_servers{$saddr}->{"srv_players"}->{"$id/$uniqueid"}))
	{
		$deleteplayer = 1;
	}
	else
	{
		&::printEvent("400", "Bad attempted delete ($saddr) ($id/$uniqueid)");
	}

	if ($deleteplayer == 1) {
		$g_servers{$saddr}->{"srv_players"}->{"$id/$uniqueid"}->playerCleanup();
		delete($g_servers{$saddr}->{"srv_players"}->{"$id/$uniqueid"});
		if (!$dontUpdateCount)  # double negative, i know...
		{
			$g_servers{$saddr}->updatePlayerCount();
		}
	}
}

sub checkBonusRound
{
   if ($g_servers{$s_addr}->{bonusroundtime} > 0 && ($::ev_remotetime > ($g_servers{$s_addr}->{bonusroundtime_ts} + $g_servers{$s_addr}->{bonusroundtime}))) {
		if ($g_servers{$s_addr}->{bonusroundtime_state} == 1) {
			&printEvent("SERVER", "Bonus Round Expired",1);
		}
		$g_servers{$s_addr}->set("bonusroundtime_state",0);
	}
	
	if($g_servers{$s_addr}->{bonusroundignore} == 1 && $g_servers{$s_addr}->{bonusroundtime_state} == 1) {
		return 1;
	}
	return 0;
}

sub is_number ($) { ( $_[0] ^ $_[0] ) eq '0' }


#
# void printNotice (string notice)
#
# Prins a debugging notice to stdout.
#

sub printNotice
{
	my ($notice) = @_;
	
	if ($g_debug > 1) {
		print ">> $notice\n";
	}
}

sub track_hlstats_trend
{
	if ($last_trend_timestamp > 0) {
		if ($last_trend_timestamp+299 < $ev_daemontime) {
			my $query = "
				SELECT 
					COUNT(*),
					a.game
				FROM
					hlstats_Players a
				INNER JOIN
					(
						SELECT
							game
						FROM
							hlstats_Servers
						GROUP BY
							game
					) AS b 
				ON
					a.game = b.game
				GROUP BY
					a.game
			";
			my $result = &execCached("get_total_player_counts", $query);
			my $insvalues = "";
			while ( my($total_players, $game) = $result->fetchrow_array) {
				my $query = "
					SELECT
						SUM(kills),
						SUM(headshots),
						COUNT(serverId),
						SUM(act_players),
						SUM(max_players)
					FROM
						hlstats_Servers
					WHERE
						game=?
				";
				my $data = &execCached("get_game_stat_counts", $query, &quoteSQL($game));
				my ($total_kills, $total_headshots, $total_servers, $act_slots, $max_slots) = $data->fetchrow_array;
				if ($max_slots > 0) {
					if ($act_slots > $max_slots) {
						$act_slots = $max_slots;
					}
				}
				if ($insvalues ne "") {
					$insvalues .= ",";
				}
				$insvalues .= "
					(
						$ev_daemontime,
						'".&quoteSQL($game)."',
						$total_players,
						$total_kills,
						$total_headshots,
						$total_servers,
						$act_slots,
						$max_slots
					)
				";
			}
			if ($insvalues ne "") {
				&execNonQuery("
					INSERT INTO
						hlstats_Trend
						(
							timestamp,
							game,
							players,
							kills,
							headshots,
							servers,
							act_slots,
							max_slots
						)
						VALUES $insvalues
				");
			}
			$last_trend_timestamp = $ev_daemontime;
			&::printEvent("HLSTATSX", "Insert new server trend timestamp", 1);
		}
	} else {
		$last_trend_timestamp = $ev_daemontime;
	}  
}

sub send_global_chat
{
	my ($message) = @_;
	while( my($server) = each(%g_servers))
	{	
		if ($server ne $s_addr && $g_servers{$server}->{"srv_players"})
		{
			my @userlist;
			my %players_temp=%{$g_servers{$server}->{"srv_players"}};
			my $pcount = scalar keys %players_temp;
			
			if ($pcount > 0) {
				while ( my($pl, $b_player) = each(%players_temp) ) {
					my $b_userid  = $b_player->{userid};
					if ($g_global_chat == 2)  {
						my $b_steamid = $b_player->{uniqueid};
						if ($g_servers{$server}->is_admin($b_steamid) == 1) {
							if (($b_player->{display_events} == 1) && ($b_player->{display_chat} == 1)) {
								push(@userlist, $b_player->{userid});
							} 
						}
					} else {  
						if (($b_player->{display_events} == 1) && ($b_player->{display_chat} == 1)) {
							push(@userlist, $b_player->{userid});
						}
					}
				}
				$g_servers{$server}->messageMany($message, 0, @userlist);
			}
		}
	}
}

#
# void buildEventInsertData ()
#
# Ran at startup to init event table queues, build initial queries, and set allowed-null columns
#

my %g_eventtable_data = ();

sub buildEventInsertData
{
	my $insertType = "";
	$insertType = " DELAYED" if ($db_lowpriority);
	while ( my ($table, $colsref) = each(%g_eventTables) )
	{
		$g_eventtable_data{$table}{queue} = [];
		$g_eventtable_data{$table}{nullallowed} = 0;
		$g_eventtable_data{$table}{lastflush} = $ev_daemontime;
		$g_eventtable_data{$table}{query} = "
		INSERT$insertType INTO
			hlstats_Events_$table
			(
				eventTime,
				serverId,
				map,
				match_id"
				;
		my $j = 0;
		foreach $i (@{$colsref})
		{
			$g_eventtable_data{$table}{query} .= ",\n$i";
			if (substr($i, 0, 4) eq 'pos_') {
				$g_eventtable_data{$table}{nullallowed} |= (1 << $j);
			}
			$j++;
		}
		$g_eventtable_data{$table}{query} .= ") VALUES\n";
	}
}

#
# void recordEvent (string table, array cols, bool getid, [mixed eventData ...])
#
# Queues an event for addition to an Events table, flushing when hitting table queue limit.
#

sub recordEvent
{
	my $table = shift;
	my $unused = shift;
	my @coldata = @_;

	# KTP: Get match_id from context if active for this server (NULL if no match)
	# Only tag events with match_id when round is live (filter freeze-time kills)
	my $ktp_match_id_sql = "NULL";
	if (defined($g_ktpMatchContext{$s_addr}) && $g_ktpMatchContext{$s_addr}{match_id} ne "") {
		if (!defined($g_ktpMatchContext{$s_addr}{round_live}) || $g_ktpMatchContext{$s_addr}{round_live}) {
			$ktp_match_id_sql = "'".quoteSQL($g_ktpMatchContext{$s_addr}{match_id})."'";
		}
	}

	my $value = "(FROM_UNIXTIME($::ev_unixtime),".$g_servers{$s_addr}->{'id'}.",'".quoteSQL($g_servers{$s_addr}->get_map())."',".$ktp_match_id_sql;
	$j = 0;
	for $i (@coldata) {
		if ($g_eventtable_data{$table}{nullallowed} & (1 << $j) && (!defined($i) || $i eq "")) {
			$value .= ",NULL";
		} elsif (!defined($i)) {
			$value .= ",''";
		} else {
			$value .= ",'".quoteSQL($i)."'";
		}
		$j++;
	}
	$value .= ")";
	
	push(@{$g_eventtable_data{$table}{queue}}, $value);
	
	if (scalar(@{$g_eventtable_data{$table}{queue}}) > $g_event_queue_size)
	{
		flushEventTable($table);
	}
}

sub flushEventTable
{
	my ($table) = @_;
	
	if (scalar(@{$g_eventtable_data{$table}{queue}}) == 0)
	{
		return;
	}
	
	my $query = $g_eventtable_data{$table}{query};
	foreach (@{$g_eventtable_data{$table}{queue}})
	{
		$query .= $_.",";
	}
	$query =~ s/,$//;
	execNonQuery($query);
	$g_eventtable_data{$table}{lastflush} = $ev_daemontime;
	$g_eventtable_data{$table}{queue} = [];
}


#
# array calcSkill (int skill_mode, int killerSkill, int killerKills, int victimSkill, int victimKills, string weapon)
#
# Returns an array, where the first index contains the killer's new skill, and
# the second index contains the victim's new skill. 
#

sub calcSkill
{
  my ($skill_mode, $killerSkill, $killerKills, $victimSkill, $victimKills, $weapon, $killerTeam) = @_;
  my @newSkill;
  
  # ignored bots never do a "comeback"
  return ($g_skill_minchange, $victimSkill) if ($killerSkill < 1);
  return ($killerSkill + $g_skill_minchange, $victimSkill) if ($victimSkill < 1);
  
  if ($g_debug > 2) {
    &printNotice("Begin calcSkill: killerSkill=$killerSkill");
    &printNotice("Begin calcSkill: victimSkill=$victimSkill");
  }

  my $modifier = 1.00;
  # Look up the weapon's skill modifier
  if (defined($g_games{$g_servers{$s_addr}->{game}}{weapons}{$weapon})) {
    $modifier = $g_games{$g_servers{$s_addr}->{game}}{weapons}{$weapon}{modifier};
  }

  # Calculate the new skills
  
  my $killerSkillChange = 0;
  if ($g_skill_ratio_cap > 0) {
    # SkillRatioCap, from *XYZ*SaYnt
    #
    # dgh...we want to cap the ratio between the victimkill and killerskill.  For example, if the number 1 player
    # kills a newbie, he gets 1000/5000 * 5 * 1 = 1 points.  If gets killed by the newbie, he gets 5000/1000 * 5 *1
    # = -25 points.   Not exactly fair.  To fix this, I'm going to cap the ratio to 1/2 and 2/1.
    # these numbers are designed such that an excellent player will have to get about a 2:1 ratio against noobs to
    # hold steady in points.
    my $lowratio = 0.7;
    my $highratio = 1.0 / $lowratio;
    my $ratio = ($victimSkill / $killerSkill);
    if ($ratio < $lowratio) { $ratio = $lowratio; }
    if ($ratio > $highratio) { $ratio = $highratio; }
    $killerSkillChange = $ratio * 5 * $modifier;
  } else {
    $killerSkillChange = ($victimSkill / $killerSkill) * 5 * $modifier;
  }

  if ($killerSkillChange > $g_skill_maxchange) {
    &printNotice("Capping killer skill change of $killerSkillChange to $g_skill_maxchange") if ($g_debug > 2);
    $killerSkillChange = $g_skill_maxchange;
  }
  
  my $victimSkillChange = $killerSkillChange;

  if ($skill_mode == 1)
  {
    $victimSkillChange = $killerSkillChange * 0.75;
  }
  elsif ($skill_mode == 2)
  {
    $victimSkillChange = $killerSkillChange * 0.5;
  }
  elsif ($skill_mode == 3)
  {
    $victimSkillChange = $killerSkillChange * 0.25;
  }
  elsif ($skill_mode == 4)
  {
    $victimSkillChange = 0;
  }
  elsif ($skill_mode == 5)
  {
    #Zombie Panic: Source only
    #Method suggested by heimer. Survivor's lose half of killer's gain when dying, but Zombie's only lose a quarter. 
    if ($killerTeam eq "Undead")
    {
      $victimSkillChange = $killerSkillChange * 0.5;
    }
    elsif ($killerTeam eq "Survivor")
    {
      $victimSkillChange = $killerSkillChange * 0.25;
    }
  }
  
  if ($victimSkillChange > $g_skill_maxchange) {
    &printNotice("Capping victim skill change of $victimSkillChange to $g_skill_maxchange") if ($g_debug > 2);
    $victimSkillChange = $g_skill_maxchange;
  }
  
  if ($g_skill_maxchange >= $g_skill_minchange) {
    if ($killerSkillChange < $g_skill_minchange) {
      &printNotice("Capping killer skill change of $killerSkillChange to $g_skill_minchange") if ($g_debug > 2);
      $killerSkillChange = $g_skill_minchange;
    } 
  
    if (($victimSkillChange < $g_skill_minchange) && ($skill_mode != 4)) {
      &printNotice("Capping victim skill change of $victimSkillChange to $g_skill_minchange") if ($g_debug > 2);
      $victimSkillChange = $g_skill_minchange;
    }
  }
  if (($killerKills < $g_player_minkills ) || ($victimKills < $g_player_minkills )) {
    $killerSkillChange = $g_skill_minchange;
    if ($skill_mode != 4) {
      $victimSkillChange = $g_skill_minchange;
    } else {
      $victimSkillChange = 0;
    }  
  }
  
  $killerSkill += $killerSkillChange;
  $victimSkill -= $victimSkillChange;
  
  # we want int not float
  $killerSkill = sprintf("%d", $killerSkill + 0.5);
  $victimSkill = sprintf("%d", $victimSkill + 0.5);
  
  if ($g_debug > 2) {
    &printNotice("End calcSkill: killerSkill=$killerSkill");
    &printNotice("End calcSkill: victimSkill=$victimSkill");
  }

  return ($killerSkill, $victimSkill);
}

sub calcL4DSkill
{
	my ($killerSkill, $weapon, $difficulty) = @_;
	
	# ignored bots never do a "comeback"
	#return ($killerSkill, $victimSkill) if ($killerSkill < 1);
	#return ($killerSkill, $victimSkill)	if ($victimSkill < 1);
	
	if ($g_debug > 2) {
		&printNotice("Begin calcSkill: killerSkill=$killerSkill");
	}

	my $modifier = 1.00;
	# Look up the weapon's skill modifier
	if (defined($g_games{$g_servers{$s_addr}->{game}}{weapons}{$weapon})) {
		$modifier = $g_games{$g_servers{$s_addr}->{game}}{weapons}{$weapon}{modifier};
	}

	# Calculate the new skills

	my $diffweight = 0.5;
	if ($difficulty > 0) {
			$diffweight = $difficulty / 2;
	}

	my $killerSkillChange = $modifier * $diffweight;

	if ($killerSkillChange > $g_skill_maxchange) {
		&printNotice("Capping killer skill change of $killerSkillChange to $g_skill_maxchange") if ($g_debug > 2);
		$killerSkillChange = $g_skill_maxchange;
	}

	if ($g_skill_maxchange >= $g_skill_minchange) {
		if ($killerSkillChange < $g_skill_minchange) {
			&printNotice("Capping killer skill change of $killerSkillChange to $g_skill_minchange") if ($g_debug > 2);
			$killerSkillChange = $g_skill_minchange;
		} 
	}
	
	$killerSkill += $killerSkillChange;
	# we want int not float
	$killerSkill = sprintf("%d", $killerSkill + 0.5);
	
	if ($g_debug > 2) {
		&printNotice("End calcSkill: killerSkill=$killerSkill");
	}
	
	return $killerSkill;
}


# Gives members of 'team' an extra 'reward' skill points. Members of the team
# who have been inactive (no events) for more than 2 minutes are not rewarded.
#

sub rewardTeam
{
	my ($team, $reward, $actionid, $actionname, $actioncode) = @_;
	$rcmd = $g_servers{$s_addr}->{broadcasting_command};
	
	my $player;
	
	&printNotice("Rewarding team \"$team\" with \"$reward\" skill for action \"$actionid\" ...");
	my @userlist;
	foreach $player (values(%g_players)) {
		my $player_team      = $player->{team};
		my $player_timestamp = $player->{timestamp};
		if (($g_servers{$s_addr}->{ignore_bots} == 1) && (($player->{is_bot} == 1) || ($player->{userid} <= 0))) {
			$desc = "(IGNORED) BOT: ";
		} else {
			if ($player_team eq $team) {
				if ($g_debug > 2) {
					&printNotice("Rewarding " . $player->getInfoString() . " with \"$reward\" skill for action \"$actionid\"");
				}
				
				&recordEvent(
					"TeamBonuses", 0,
					$player->{playerid},
					$actionid,
					$reward
					);
				$player->increment("skill", $reward, 1);
				$player->increment("session_skill", $reward, 1);
				$player->updateDB();
			}
			if ($player->{is_bot} == 0 && $player->{userid} > 0 && $player->{display_events} == 1) {
				push(@userlist, $player->{userid});
			}    
		}
	}
	if (($g_servers{$s_addr}->{broadcasting_events} == 1) && ($g_servers{$s_addr}->{broadcasting_player_actions} == 1)) {
		my $coloraction = $g_servers{$s_addr}->{format_action};
		my $verb = "got";
		if ($reward < 0) {
			$verb = "lost";
		}
		my $msg = sprintf("%s %s %s points for %s%s", $team, $verb, abs($reward), $coloraction, $actionname);
		$g_servers{$s_addr}->messageMany($msg, 0, @userlist);
	}
}


#
# int getPlayerId (uniqueId)
#
# Looks up a player's ID number, from their unique (WON) ID. Returns their PID.
#

sub getPlayerId
{
	my ($uniqueId) = @_;

	my $query = "
		SELECT
			playerId
		FROM
			hlstats_PlayerUniqueIds
		WHERE
			uniqueId='" . &::quoteSQL($uniqueId) . "' AND
			game='" . $g_servers{$s_addr}->{game} . "'
	";
	my $result = &doQuery($query);

	if ($result->rows > 0) {
		my ($playerId) = $result->fetchrow_array;
		$result->finish;
		return $playerId;
	} else {
		$result->finish;
		return 0;
	}
}


#
# int updatePlayerProfile (object player, string field, string value)
#
# Updates a player's profile information in the database.
#

sub updatePlayerProfile
{
	my ($player, $field, $value) = @_;
	$rcmd = $g_servers{$s_addr}->{player_command};
	
	unless ($player) {
		&printNotice("updatePlayerInfo: Bad player");
		return 0;
	}

	$value = &quoteSQL($value);
	if ($value eq "none" || $value eq " ") {
		$value = "";
	}
	
	my $playerName = &abbreviate($player->{name});
	my $playerId   = $player->{playerid};

	&execNonQuery("
		UPDATE
			hlstats_Players
		SET
			$field='$value'
		WHERE
			playerId=$playerId
	");
	
	if ($g_servers{$s_addr}->{player_events} == 1) {
		my $p_userid  = $g_servers{$s_addr}->format_userid($player->{userid});
		my $p_is_bot  = $player->{is_bot};
		$cmd_str = $rcmd." $p_userid ".$g_servers{$s_addr}->quoteparam("SET command successful for '$playerName'.");
		$g_servers{$s_addr}->dorcon($cmd_str);
	}
	return 1;
}

#
# mixed getClanId (string name)
#
# Looks up a player's clan ID from their name. Compares the player's name to tag
# patterns in hlstats_ClanTags. Patterns look like:  [AXXXXX] (matches 1 to 6
# letters inside square braces, e.g. [ZOOM]Player)  or  =\*AAXX\*= (matches
# 2 to 4 letters between an equals sign and an asterisk, e.g.  =*RAGE*=Player).
#
# Special characters in the pattern:
#    A    matches one character  (i.e. a character is required)
#    X    matches zero or one characters  (i.e. a character is optional)
#    a    matches literal A or a
#    x    matches literal X or x
#
# If no clan exists for the tag, it will be created. Returns the clan's ID, or
# 0 if the player is not in a clan.
#

sub getClanId
{
	my ($name) = @_;
	my $clanTag  = "";
	my $clanName = "";
	my $clanId   = 0;
	my $result = &doQuery("
		SELECT
			pattern,
			position,
			LENGTH(pattern) AS pattern_length
		FROM
			hlstats_ClanTags
		ORDER BY
			pattern_length DESC,
			id
	");
	
	while ( my($pattern, $position) = $result->fetchrow_array) {
		my $regpattern = quotemeta($pattern);
		$regpattern =~ s/([A-Za-z0-9]+[A-Za-z0-9_-]*)/\($1\)/; # to find clan name from tag
		$regpattern =~ s/A/./g;
		$regpattern =~ s/X/.?/g;
		
		if ($g_debug > 2) {
			&printNotice("regpattern=$regpattern");
		}
		
		if ((($position eq "START" || $position eq "EITHER") && $name =~ /^($regpattern).+/i) ||
			(($position eq "END"   || $position eq "EITHER") && $name =~ /.+($regpattern)$/i)) {
			
			if ($g_debug > 2) {
				&printNotice("pattern \"$regpattern\" matches \"$name\"! 1=\"$1\" 2=\"$2\"");
			}
			
			$clanTag  = $1;
			$clanName = $2;
			last;
		}
	}
	
	unless ($clanTag) {
		return 0;
	}

	my $query = "
		SELECT
			clanId
		FROM
			hlstats_Clans
		WHERE
			tag='" . &quoteSQL($clanTag) . "' AND
			game='$g_servers{$s_addr}->{game}'
		";
	$result = &doQuery($query);

	if ($result->rows) {
		($clanId) = $result->fetchrow_array;
		$result->finish;
		return $clanId;
	} else {
		# The clan doesn't exist yet, so we create it.
		$query = "
			REPLACE INTO
				hlstats_Clans
				(
					tag,
					name,
					game
				)
			VALUES
			(
				'" . &quoteSQL($clanTag)  . "',
				'" . &quoteSQL($clanName) . "',
				'".&quoteSQL($g_servers{$s_addr}->{game})."'
			)
		";
		&execNonQuery($query);
		
		$clanId = $db_conn->{'mysql_insertid'};

		&printNotice("Created clan \"$clanName\" <C:$clanId> with tag "
				. "\"$clanTag\" for player \"$name\"");
		return $clanId;
	}
}

#
# object getServer (string address, int port)
#
# Looks up a server's ID number in the Servers table, by searching for a
# matching IP address and port. NOTE you must specify IP addresses in the
# Servers table, NOT hostnames.
#
# Returns a new "Server object".
#

sub getServer
{
	my ($address, $port) = @_;

	my $query = "
		SELECT
			a.serverId,
			a.game,
			a.name,
			a.rcon_password,
			a.publicaddress,
			IFNULL(b.`value`,3) AS game_engine,
			IFNULL(c.`realgame`, 'hl2mp') AS realgame,
			IFNULL(a.max_players, 0) AS maxplayers
			
		FROM
			hlstats_Servers a LEFT JOIN hlstats_Servers_Config b on a.serverId = b.serverId AND b.`parameter` = 'GameEngine' LEFT JOIN `hlstats_Games` c ON a.game = c.code
		WHERE
			address=? AND
			port=? LIMIT 1
		";
	my @vals = (
		$address,
		$port
	);
	my $result = &execCached("get_server_information", $query, @vals);

	if ($result->rows) {
		my ($serverId, $game, $name, $rcon_pass, $publicaddress, $gameengine, $realgame, $maxplayers) = $result->fetchrow_array;
		$result->finish;
		if (!defined($g_games{$game})) {
			$g_games{$game} = new HLstats_Game($game);
			&ktpAssertActionsSeeded($game);
		}
		# l4d code should be reused for l4d2
		# trying first using l4d as "realgame" code for l4d2 in db. if default server config settings won't work, will leave as own "realgame" code in db but uncomment line.
		#$realgame = "l4d" if $realgame eq "l4d2";
		
		return new HLstats_Server($serverId, $address, $port, $name, $rcon_pass, $game, $publicaddress, $gameengine, $realgame, $maxplayers);
	} else {
		$result->finish;
		return 0;
	}
}

#
# 
#
#
#

sub queryServer
{
	my ($iaddr, $iport, @query)            = @_;
	my $game = "";
	my $timeout=2;
	my $message = IO::Socket::INET->new(Proto=>"udp",Timeout=>$timeout,PeerPort=>$iport,PeerAddr=>$iaddr) or die "Can't make UDP socket: $@";
	$message->send("\xFF\xFF\xFF\xFFTSource Engine Query\x00");
	my ($datagram,$flags);
	my $end = time + $timeout;
	my $rin = '';
	vec($rin, fileno($message), 1) = 1;

	my %hash = ();

	while (1) {
		my $timeleft = $end - time;
		last if ($timeleft <= 0);
		my ($nfound, $t) = select(my $rout = $rin, undef, undef, $timeleft);
		last if ($nfound == 0); # either timeout or end of file
		$message->recv($datagram,1024,$flags);
		@hash{qw/key type netver hostname mapname gamedir gamename id numplayers maxplayers numbots dedicated os passreq secure gamever edf port/} = unpack("LCCZ*Z*Z*Z*vCCCCCCCZ*Cv",$datagram);
	}

	return @hash{@query};
}


sub getServerMod
{
	my ($address, $port) = @_;
	my ($playgame);

	&printEvent ("DETECT", "Querying $address".":$port for gametype");

	my @query = (
			'gamename',
			'gamedir',
			'hostname',
			'numplayers',
			'maxplayers',
			'mapname'
			);

	my ($gamename, $gamedir, $hostname, $numplayers, $maxplayers, $mapname) = &queryServer($address, $port, @query);

	if ($gamename =~ /^Counter-Strike$/i) {
		$playgame = "cstrike";
	} elsif ($gamename =~ /^Counter-Strike/i) {
		$playgame = "css";
	} elsif ($gamename =~ /^Team Fortress C/i) {
		$playgame = "tfc";
	} elsif ($gamename =~ /^Team Fortress/i) {
		$playgame = "tf";
	} elsif ($gamename =~ /^Day of Defeat$/i) {
		$playgame = "dod";
	} elsif ($gamename =~ /^Day of Defeat/i) {
		$playgame = "dods";
	} elsif ($gamename =~ /^Insurgency/i) {
		$playgame = "insmod";
	} elsif ($gamename =~ /^Neotokyo/i) {
		$playgame = "nts";
	} elsif ($gamename =~ /^Fortress Forever/i) {
		$playgame = "ff";
	} elsif ($gamename =~ /^Age of Chivalry/i) {
		$playgame = "aoc";
	} elsif ($gamename =~ /^Dystopia/i) {
		$playgame = "dystopia";
	} elsif ($gamename =~ /^Stargate/i) {
		$playgame = "sgtls";
	} elsif ($gamename =~ /^Battle Grounds/i) {
		$playgame = "bg2";
	} elsif ($gamename =~ /^Hidden/i) {
		$playgame = "hidden";
	} elsif ($gamename =~ /^L4D /i) {
		$playgame = "l4d";
	} elsif ($gamename =~ /^Left 4 Dead 2/i) {
		$playgame = "l4d2";
	} elsif ($gamename =~ /^ZPS /i) {
		$playgame = "zps";
	} elsif ($gamename =~ /^NS /i) {
		$playgame = "ns";
	} elsif ($gamename =~ /^pvkii/i) {
		$playgame = "pvkii";
	} elsif ($gamename =~ /^CSPromod/i) {
		$playgame = "csp";
	} elsif ($gamename eq "Half-Life") {
		$playgame = "valve";
	} elsif ($gamename eq "Nuclear Dawn") {
		$playgame = "nucleardawn";
    
	# We didn't found our mod, trying secondary way. This is required for some games such as FOF and GES and is a fallback for others
	} elsif ($gamedir =~ /^ges/i) {
		$playgame = "ges";
	} elsif ($gamedir =~ /^fistful_of_frags/i || $gamedir =~ /^fof/i) {
		$playgame = "fof";
	} elsif ($gamedir =~ /^hl2mp/i) {
		$playgame = "hl2mp";
	} elsif ($gamedir =~ /^tfc/i) {
		$playgame = "tfc";
	} elsif ($gamedir =~ /^tf/i) {
		$playgame = "tf";
	} elsif ($gamedir =~ /^ins/i) {
		$playgame = "insmod";
	} elsif ($gamedir =~ /^neotokyo/i) {
		$playgame = "nts";
	} elsif ($gamedir =~ /^fortressforever/i) {
		$playgame = "ff";
	} elsif ($gamedir =~ /^ageofchivalry/i) {
		$playgame = "aoc";
	} elsif ($gamedir =~ /^dystopia/i) {
		$playgame = "dystopia";
	} elsif ($gamedir =~ /^sgtls/i) {
		$playgame = "sgtls";
	} elsif ($gamedir =~ /^hidden/i) {
		$playgame = "hidden";
	} elsif ($gamedir =~ /^left4dead/i) {
		$playgame = "l4d";
	} elsif ($gamedir =~ /^left4dead2/i) {
		$playgame = "l4d2";
	} elsif ($gamedir =~ /^zps/i) {
		$playgame = "zps";
	} elsif ($gamedir =~ /^ns/i) {
		$playgame = "ns";
	} elsif ($gamedir =~ /^bg/i) {
		$playgame = "bg2";
	} elsif ($gamedir =~ /^pvkii/i) {
		$playgame = "pvkii";
	} elsif ($gamedir =~ /^cspromod/i) {
		$playgame = "csp";
	} elsif ($gamedir =~ /^valve$/i) {
		$playgame = "valve";
    } elsif ($gamedir =~ /^nucleardawn$/i) {
		$playgame = "nucleardawn";
	} elsif ($gamedir =~ /^dinodday$/i) {
		$playgame = "dinodday";
	} else {
		# We didn't found our mod, giving up.
		&printEvent("DETECT", "Failed to get Server Mod");
		return 0;
	}
	&printEvent("DETECT", "Saving server " . $address . ":" . $port . " with gametype " . $playgame);
	&addServerToDB($address, $port, $hostname, $playgame, $numplayers, $maxplayers, $mapname);
	return $playgame;
}

sub addServerToDB
{
	my ($address, $port, $name, $game, $act_players, $max_players, $act_map) = @_;
	my $sql = "INSERT INTO hlstats_Servers (address, port, name, game, act_players, max_players, act_map) VALUES ('$address', $port, '".&quoteSQL($name)."', '".&quoteSQL($game)."', $act_players, $max_players, '".&quoteSQL($act_map)."')";
	&execNonQuery($sql);
   
	my $last_id = $db_conn->{'mysql_insertid'};
	&execNonQuery("DELETE FROM `hlstats_Servers_Config` WHERE serverId = $last_id");
	&execNonQuery("INSERT INTO `hlstats_Servers_Config` (`serverId`, `parameter`, `value`)
				SELECT $last_id, `parameter`, `value`
				FROM `hlstats_Mods_Defaults` WHERE `code` = '';");
	&execNonQuery("INSERT INTO `hlstats_Servers_Config` (`serverId`, `parameter`, `value`) VALUES
				($last_id, 'Mod', '');");
	&execNonQuery("INSERT INTO `hlstats_Servers_Config` (`serverId`, `parameter`, `value`)
				SELECT $last_id, `parameter`, `value`
				FROM `hlstats_Games_Defaults` WHERE `code` = '".&quoteSQL($game)."'
				ON DUPLICATE KEY UPDATE `value` = VALUES(`value`);");   
	&readDatabaseConfig();

	return 1;
}

#
# boolean sameTeam (string team1, string team2)
#
# This should be expanded later to allow for team alliances (e.g. TFC-hunted).
#

sub sameTeam
{
	my ($team1, $team2) = @_;
	
	if (($team1 eq $team2) && (($team1 ne "Unassigned") || ($team2 ne "Unassigned"))) {
		return 1;
	} else {
		return 0;
	}
}


#
# string getPlayerInfoString (object player, string ident)
#

sub getPlayerInfoString
{
	my ($player) = shift;
	my @ident = @_;
	
	if ($player) {
		return $player->getInfoString();
	} else {
		return "(" . join(",", @ident) . ")";
	}
}



#
# array getPlayerInfo (string player, string $ipAddr)
#
# Get a player's name, uid, wonid and team from "Name<uid><wonid><team>".
#

sub getPlayerInfo
{
	my ($player, $create_player, $ipAddr) = @_;

	if ($player =~ /^(.*?)<(\d+)><([^<>]*)><([^<>]*)>(?:<([^<>]*)>)?.*$/) {
		my $name		= $1;
		my $userid		= $2;
		my $uniqueid	= $3;
		my $team		= $4;
		my $role		= $5;
		my $bot			= 0;
		my $haveplayer  = 0;
		
		$plainuniqueid = $uniqueid;
		$uniqueid =~ s!\[U:1:(\d+)\]!'STEAM_0:'.($1 % 2).':'.int($1 / 2)!eg;
		$uniqueid =~ s/^STEAM_[0-9]+?\://;
		
		if (($uniqueid eq "Console") && ($team eq "Console")) {
		  return 0;
		}
		if ($g_servers{$s_addr}->{play_game} == L4D()) {
		#for l4d, create meta player object for each role
			if ($uniqueid eq "") {
				#infected & witch have blank steamid
				if ($name eq "infected") {
					$uniqueid = "BOT-Horde";
					$team = "Infected";
					$userid = -9;
				} elsif ($name eq "witch") {
					$uniqueid = "BOT-Witch";
					$team = "Infected";
					$userid = -10;
				} else {
					return 0;
				}
			} elsif ($uniqueid eq "BOT") {
				#all other bots have BOT for steamid
				if ($team eq "Survivor") {
					if ($name eq "Nick") {
						$userid = -11;
					} elsif ($name eq "Ellis") {
						$userid = -13;
					} elsif ($name eq "Rochelle") {
						$userid = -14;
					} elsif ($name eq "Coach") {
						$userid = -12;
					} elsif ($name eq "Louis") {
						$userid = -4;
					} elsif ($name eq "Zoey") {
						$userid = -1;
					} elsif ($name eq "Francis") {
						$userid = -2;
					} elsif ($name eq "Bill") {
						$userid = -3;
					} else {
						&printEvent("ERROR", "No survivor match for $name",0,1);
						$userid = -4;
					}
				} else {
					if ($name eq "Smoker") {
						$userid = -5;
					} elsif ($name eq "Boomer") {
						$userid = -6;
					} elsif ($name eq "Hunter") {
						$userid = -7;
					} elsif ($name eq "Spitter") {
						$userid = -15;
					} elsif ($name eq "Jockey") {
						$userid = -16;
					} elsif ($name eq "Charger") {
						$userid = -17;
					} elsif ($name eq "Tank") {
						$userid = -8;
					} else {
						&printEvent("DEBUG", "No infected match for $name",0,1);
						$userid = -8;
					}
				}
				$uniqueid = "BOT-".$name;
				$name = "BOT-".$name;
			}
		}

		if ($ipAddr eq "none") {
			$ipAddr = "";
		}
		
		$bot = botidcheck($uniqueid);
		
		if ($g_mode eq "NameTrack") {
			$uniqueid = $name;
		} else {
			if ($g_mode eq "LAN" && !$bot && $userid > 0) {
				if ($ipAddr ne "") {
					$g_lan_noplayerinfo{"$s_addr/$userid/$name"} = {
						ipaddress => $ipAddr,
						userid => $userid,
						name => $name,
						server => $s_addr
						};
					$uniqueid = $ipAddr;
				} else {
					while ( my($index, $player) = each(%g_players) ) {
						if (($player->{userid} eq $userid) &&
							($player->{name}   eq $name)) {
						
							$uniqueid = $player->{uniqueid}; 
							$haveplayer = 1;
							last;
						}   
					}
					if (!$haveplayer) {
						while ( my($index, $player) = each(%g_lan_noplayerinfo) ) {
							if (($player->{server} eq $s_addr) &&
								($player->{userid} eq $userid) &&
								($player->{name}   eq $name)) {
						
								$uniqueid = $player->{ipaddress}; 
								$haveplayer = 1;
							}    
						}  
					}
					if (!$haveplayer) {
						$uniqueid = "UNKNOWN";
					}
				}
			} else {
				# Normal (steamid) mode player and bot, as well as lan mode bots
				if ($bot) {
					$md5 = Digest::MD5->new;
					$md5->add($name);
					$md5->add($s_addr);
					$uniqueid = "BOT:" . $md5->hexdigest;
					$unique_id = $uniqueid if ($g_mode eq "LAN");
				}
			
				if ($uniqueid eq "UNKNOWN"
					|| $uniqueid eq "STEAM_ID_PENDING" || $uniqueid eq "STEAM_ID_LAN"
					|| $uniqueid eq "VALVE_ID_PENDING" || $uniqueid eq "VALVE_ID_LAN"
				) {
					return {
						name     => $name,
						userid   => $userid,
						uniqueid => $uniqueid,
						team     => $team,
						is_bot   => $bot
					};
				}
			}
		}
		
		if (!$haveplayer)
		{
			while ( my ($index, $player) = each(%g_players) ) {
				# Cannot exit loop early as more than one player can exist with same uniqueid
				# (bug? or just bad logging)
				# Either way, we disconnect any that don't match the current line
				if ($player->{uniqueid} eq $uniqueid) {
					$haveplayer = 1;
					# Catch players reconnecting without first disconnecting
					if ($player->{userid} != $userid) {
					
						&doEvent_Disconnect(
							$player->{"userid"},
							$uniqueid,
							""
						);
						$haveplayer = 0;
					}
				}
			}
		}
		
		if ($haveplayer) {
			my $player = lookupPlayer($s_addr, $userid, $uniqueid);
			if ($player) {
				#  The only time team should go /back/ to unassigned ("") is on mapchange
				#  (which is already handled in the ChangeMap handler)
				#  So ignore when team is blank (<>) from lazy log lines
				if ($team ne "" && $player->{team} ne $team) {
					&doEvent_TeamSelection(
						$userid,
						$uniqueid,
						$team
					);
				}
				if ($role ne "" && $role ne $player->{role}) {
					&doEvent_RoleSelection(
						$player->{"userid"},
						$player->{"uniqueid"},
						$role
					);
				}
				
				$player->updateTimestamp();
			}  
		} else {
			if ($userid != 0) {
				if ($create_player > 0) {
					my $preIpAddr = "";
					if ($g_preconnect->{"$s_addr/$userid/$name"}) {
						$preIpAddr = $g_preconnect->{"$s_addr/$userid/$name"}->{"ipaddress"};
					}
					# Add the player to our hash of player objects
					$g_servers{$s_addr}->{"srv_players"}->{"$userid/$uniqueid"} = new HLstats_Player(
						server => $s_addr,
						server_id => $g_servers{$s_addr}->{id},
						userid => $userid,
						uniqueid => $uniqueid,
						plain_uniqueid => $plainuniqueid,
						game => $g_servers{$s_addr}->{game},
						name => $name,
						team => $team,
						role => $role,
						is_bot => $bot,
						display_events => $g_servers{$s_addr}->{default_display_events},
						address => (($preIpAddr ne "") ? $preIpAddr : $ipAddr)
					);
					
					if ($preIpAddr ne "") {
						&printEvent("SERVER", "LATE CONNECT [$name/$userid] - steam userid validated");
						&doEvent_Connect($userid, $uniqueid, $preIpAddr);
						delete($g_preconnect->{"$s_addr/$userid/$name"});
					}
					# Increment number of players on server
					$g_servers{$s_addr}->updatePlayerCount();
				}  
			} elsif (($g_mode eq "LAN") && (defined($g_lan_noplayerinfo{"$s_addr/$userid/$name"}))) {
				if ((!$haveplayer) && ($uniqueid ne "UNKNOWN") && ($create_player > 0)) {
					$g_servers{$s_addr}->{srv_players}->{"$userid/$uniqueid"} = new HLstats_Player(
						server => $s_addr,
						server_id => $g_servers{$s_addr}->{id},
						userid => $userid,
						uniqueid => $uniqueid,
						plain_uniqueid => $plainuniqueid,
						game => $g_servers{$s_addr}->{game},
						name => $name,
						team => $team,
						role => $role,
						is_bot => $bot
					);
					delete($g_lan_noplayerinfo{"$s_addr/$userid/$name"});
					# Increment number of players on server
					
					$g_servers{$s_addr}->updatePlayerCount();
				} 
			} else {
				&printNotice("No player object available for player \"$name\" <U:$userid>");
			}
		}
		
		return {
			name     => $name,
			userid   => $userid,
			uniqueid => $uniqueid,
			team     => $team,
			is_bot   => $bot
		};
	} elsif ($player =~ /^(.+)<([^<>]+)>$/) {
		my $name     = $1;
		my $uniqueid = $2;
		my $bot      = 0;
		
		if (&botidcheck($uniqueid)) {
			$md5 = Digest::MD5->new;
			$md5->add($ev_daemontime);
			$md5->add($s_addr);
			$uniqueid = "BOT:" . $md5->hexdigest;
			$bot = 1;
		}
		return {
			name     => $name,
			uniqueid => $uniqueid,
			is_bot   => $bot
		};
	} elsif ($player =~ /^<><([^<>]+)><>$/) {
		my $uniqueid = $1;
		my $bot      = 0;
		if (&botidcheck($uniqueid)) {
			$md5 = Digest::MD5->new;
			$md5->add($ev_daemontime);
			$md5->add($s_addr);
			$uniqueid = "BOT:" . $md5->hexdigest;
			$bot = 1;
		}
		return {
			uniqueid => $uniqueid,
			is_bot   => $bot
		};
	} else {
		return 0;
	}
}


#
# hash getProperties (string propstring)
#
# Parse (key "value") properties into a hash.
#

sub getProperties
{
	my ($propstring) = @_;
	my %properties;
	my $dods_flag = 0;
	
	# `.*?` not `.+?`: an EMPTY quoted value must match here. With `.+?` the
	# quoted branch cannot match `(matchid "")` at all, so the lazy match runs on
	# to the NEXT quote pair and yields `") (map "dod_harrington` as the value --
	# a phantom match id that spread across 13 tables before anyone noticed.
	# Nothing errors, which is why it survived. Test with an empty field: a
	# malformed-input suite passes while this case still breaks.
	# `[^\s()]+` not `\S+` for the KEY: a bare-boolean key is followed by the next
	# property's own paren, and `\S+` swallows it -- `(flagindex) (map "x")` parses the
	# key as `flagindex)` and loses the pair. Measured output-neutral on 32k real tails.
	while ($propstring =~ s/^\s*\(([^\s()]+)(?:(?: "(.*?)")|(?: ([^\)]+)))?\)//) {
		my $key = $1;
		if (defined($2)) {
			if ($key eq "player") {
				if ($dods_flag == 1) {
					$key = "player_a";
					$dods_flag++;
				} elsif ($dods_flag == 2) {
					$key = "player_b";
				}
			}
			$properties{$key} = $2;
		} elsif (defined($3)) {
			$properties{$key} = $3;
		} else {
			$properties{$key} = 1; # boolean property
		}
		if ($key eq "flagindex") {
			$dods_flag++;
		}
	}
	
	return %properties;
}


# 
# boolean like (string subject, string compare)
#
# Returns true if 'subject' equals 'compare' with optional whitespace.
#

sub like
{
	my ($subject, $compare) = @_;
	
	if ($subject =~ /^\s*\Q$compare\E\s*$/) {
		return 1;
	} else {
		return 0;
	}
}


# 
# boolean botidcheck (string uniqueid)
#
# Returns true if 'uniqueid' is that of a bot.
#

sub botidcheck
{
	# needs cleaned up
	# added /^00000000\:\d+\:0$/ check for "whichbot"
	my ($uniqueid) = @_;
	if ($uniqueid eq "BOT" || $uniqueid eq "0" || $uniqueid =~ /^00000000\:\d+\:0$/) {
		return 1
	}
	return 0;
}

sub isTrackableTeam
{
	my ($team) = @_;
	#if ($team =~ /spectator/i || $team =~ /unassigned/i || $team eq "") {
	if ($team =~ /spectator/i || $team eq "") {
		return 0;
	}
	return 1;
}

sub reloadConfiguration
{
	&flushAll;
	&readDatabaseConfig;
}


sub flushAll
{
	# we only need to flush events if we're about to shut down. they are unaffected by server/player deletion
	my ($flushevents) = @_;
	if ($flushevents)
	{
		flushAccumulators();
		while ( my ($table, $colsref) = each(%g_eventTables) )
		{
			flushEventTable($table);
		}
		%g_ktpScoreAccum = ();  # KTP: Clear score accumulator on shutdown
	}

	while( my($se, $server) = each(%g_servers))
	{
		while ( my($pl, $player) = each(%{$server->{"srv_players"}}) )
		{
			if ($player)
			{
				$player->playerCleanup();
			}
		}
		$server->flushDB();
	}
}


#
# KTP: Flush in-memory accumulators to database
# Batches Roles, Weapons, and Maps_Counts UPDATEs to reduce MySQL round-trips
#
sub flushAccumulators
{
	# Flush Roles accumulator: kills and deaths per game:role
	while (my ($key, $counts) = each(%g_roles_accum)) {
		my ($game, $code) = split(/:/, $key, 2);
		next if (!defined($game) || !defined($code));
		my $set_parts = "";
		if (($counts->{kills} || 0) > 0) {
			$set_parts .= "kills=kills+" . int($counts->{kills});
		}
		if (($counts->{deaths} || 0) > 0) {
			$set_parts .= ", " if ($set_parts ne "");
			$set_parts .= "deaths=deaths+" . int($counts->{deaths});
		}
		if ($set_parts ne "") {
			&execNonQuery("UPDATE hlstats_Roles SET $set_parts WHERE game='" . &quoteSQL($game) . "' AND code='" . &quoteSQL($code) . "'");
		}
	}
	%g_roles_accum = ();

	# Flush Weapons accumulator: kills and headshots per game:weapon
	while (my ($key, $counts) = each(%g_weapons_accum)) {
		my ($game, $code) = split(/:/, $key, 2);
		next if (!defined($game) || !defined($code));
		my $set_parts = "kills=kills+" . int($counts->{kills} || 0);
		if (($counts->{headshots} || 0) > 0) {
			$set_parts .= ", headshots=headshots+" . int($counts->{headshots});
		}
		&execNonQuery("UPDATE hlstats_Weapons SET $set_parts WHERE game='" . &quoteSQL($game) . "' AND code='" . &quoteSQL($code) . "'");
	}
	%g_weapons_accum = ();

	# Flush Maps_Counts accumulator: kills and headshots per game:map
	while (my ($key, $counts) = each(%g_maps_accum)) {
		my ($game, $map) = split(/:/, $key, 2);
		next if (!defined($game) || !defined($map));
		my $kills = int($counts->{kills} || 0);
		my $headshots = int($counts->{headshots} || 0);
		&execNonQuery("
			INSERT INTO hlstats_Maps_Counts (game, map, kills, headshots)
			VALUES ('" . &quoteSQL($game) . "', '" . &quoteSQL($map) . "', $kills, $headshots)
			ON DUPLICATE KEY UPDATE kills=kills+$kills, headshots=headshots+$headshots
		");
	}
	%g_maps_accum = ();
}


##
## MAIN
##

# Options

$opt_help = 0;
$opt_version = 0;

$db_host = "localhost";
$db_user = "";
$db_pass = "";
$db_name = "hlstats";
$db_lowpriority = 1;

$s_ip = "";
$s_port = "27500";

$g_mailto = "";
$g_mailpath = "/bin/mail";
$g_mode = "Normal";
$g_deletedays = 5;
$g_requiremap = 0;
$g_debug = 1;
$g_nodebug = 0;
$g_rcon = 1;
$g_rcon_ignoreself = 0;
$g_rcon_record = 1;
$g_stdin = 0;
$g_server_ip = "";
$g_server_port = 27015;
$g_timestamp = 0;
$g_cpanelhack = 0;
$g_event_queue_size = 100;
$g_dns_resolveip = 1;
$g_dns_timeout = 5;
$g_skill_maxchange = 100;
$g_skill_minchange = 2;
$g_skill_ratio_cap = 0;
$g_geoip_binary = 0;
$g_player_minkills = 50;
$g_onlyconfig_servers = 1;
$g_track_stats_trend = 0;
%g_lan_noplayerinfo = ();
%g_preconnect = ();
$g_global_banning = 0;
$g_log_chat = 0;
$g_log_chat_admins = 0;
$g_global_chat = 0;
$g_ranktype = "skill";
$g_gi = undef;

my %dysweaponcodes = (
	"1" => "Light Katana",
	"2" => "Medium Katana",
	"3" => "Fatman Fist",
	"4" => "Machine Pistol",
	"5" => "Shotgun",
	"6" => "Laser Rifle",
	"7" => "BoltGun",
	"8" => "SmartLock Pistols",
	"9" => "Assault Rifle",
	"10" => "Grenade Launcher",
	"11" => "MK-808 Rifle",
	"12" => "Tesla Rifle",
	"13" => "Rocket Launcher",
	"14" => "Minigun",
	"15" => "Ion Cannon",
	"16" => "Basilisk",
	"17" => "Frag Grenade",
	"18" => "EMP Grenade",
	"19" => "Spider Grenade",
	"22" => "Cortex Bomb"
);

# Usage message

$usage = <<EOT
Usage: hlstats.pl [OPTION]...
Collect statistics from one or more Half-Life2 servers for insertion into
a MySQL database.

  -h, --help                      display this help and exit  
  -v, --version                   output version information and exit
  -d, --debug                     enable debugging output (-dd for more)
  -n, --nodebug                   disables above; reduces debug level
  -m, --mode=MODE                 player tracking mode (Normal, LAN or NameTrack)  [$g_mode]
      --db-host=HOST              database ip or ip:port  [$db_host]
      --db-name=DATABASE          database name  [$db_name]
      --db-password=PASSWORD      database password (WARNING: specifying the
                                    password on the command line is insecure.
                                    Use the configuration file instead.)
      --db-username=USERNAME      database username
      --dns-resolveip             resolve player IP addresses to hostnames
                                    (requires working DNS)
   -c,--configfile                Specific configfile to use, settings in this file can now
                                    be overidden with commandline settings.
      --nodns-resolveip           disables above
      --dns-timeout=SEC           timeout DNS queries after SEC seconds  [$g_dns_timeout]
  -i, --ip=IP                     set IP address to listen on for UDP log data
  -p, --port=PORT                 set port to listen on for UDP log data  [$s_port]
  -r, --rcon                      enables rcon command exec support (the default)
      --norcon                    disables rcon command exec support
  -s, --stdin                     read log data from standard input, instead of
                                    from UDP socket. Must specify --server-ip
                                    and --server-port to indicate the generator
                                    of the inputted log data (implies --norcon)
      --nostdin                   disables above
      --server-ip                 specify data source IP address for --stdin
      --server-port               specify data source port for --stdin  [$g_server_port]
  -t, --timestamp                 tells HLstatsX:CE to use the timestamp in the log
                                    data, instead of the current time on the
                                    database server, when recording events
      --notimestamp               disables above
      --event-queue-size=SIZE     manually set event queue size to control flushing
                                    (recommend 100+ for STDIN)

Long options can be abbreviated, where such abbreviation is not ambiguous.
Default values for options are indicated in square brackets [...].

Most options can be specified in the configuration file:
  $opt_configfile
Note: Options set on the command line take precedence over options set in the
configuration file. The configuration file name is set at the top of hlstats.pl.

HLstatsX: Community Edition http://www.hlxcommunity.com
EOT
;

%g_config_servers = ();


sub readDatabaseConfig()
{
	&printEvent("CONFIG", "Reading database config...", 1);
	%g_config_servers = ();
	%g_servers = ();
	%g_games = ();

	# elstatsneo: read the servers portion from the mysql database
	my $srv_id = &doQuery("SELECT serverId,CONCAT(address,':',port) AS addr FROM hlstats_Servers");
	while ( my($serverId,$addr) = $srv_id->fetchrow_array) {
		$g_config_servers{$addr} = ();
		my $serverConfig = &doQuery("SELECT parameter,value FROM hlstats_Servers_Config WHERE serverId=$serverId");
		while ( my($p,$v) = $serverConfig->fetchrow_array) {
			$g_config_servers{$addr}{$p} = $v;
		}
	}
	$srv_id->finish;
	# hlxce: read the global settings from the database!
	my $gsettings = &doQuery("SELECT keyname,value FROM hlstats_Options WHERE opttype <= 1");
	while ( my($p,$v) = $gsettings->fetchrow_array) {
		if ($g_debug > 1) {
			print "Config parameter '$p' = '$v'\n";
		}
		$tmp = "\$".$directives_mysql{$p}." = '$v'";
		#print " -> setting ".$tmp."\n";
		eval $tmp;
	}
	$gsettings->finish;
	# setting defaults

	&printEvent("DAEMON", "Proxy_Key DISABLED", 1) if ($proxy_key eq "");
	while (my($addr, $server) = each(%g_config_servers)) {
		
		if (!defined($g_config_servers{$addr}{"MinPlayers"})) {
			$g_config_servers{$addr}{"MinPlayers"}						= 6;
		}  
		if (!defined($g_config_servers{$addr}{"DisplayResultsInBrowser"})) {
			$g_config_servers{$addr}{"DisplayResultsInBrowser"}			= 0;
		}  
		if (!defined($g_config_servers{$addr}{"BroadCastEvents"})) {
			$g_config_servers{$addr}{"BroadCastEvents"}					= 0;
		}
		if (!defined($g_config_servers{$addr}{"BroadCastPlayerActions"})) {
			$g_config_servers{$addr}{"BroadCastPlayerActions"}			= 0;
		}
		if (!defined($g_config_servers{$addr}{"BroadCastEventsCommand"})) {
			$g_config_servers{$addr}{"BroadCastEventsCommand"}			= "say";
		}
		if (!defined($g_config_servers{$addr}{"BroadCastEventsCommandAnnounce"})) {
			$g_config_servers{$addr}{"BroadCastEventsCommandAnnounce"}	= "say";
		}
		if (!defined($g_config_servers{$addr}{"PlayerEvents"})) {
			$g_config_servers{$addr}{"PlayerEvents"}					= 1;
		}
		if (!defined($g_config_servers{$addr}{"PlayerEventsCommand"})) {
			$g_config_servers{$addr}{"PlayerEventsCommand"}				= "say";
		}
		if (!defined($g_config_servers{$addr}{"PlayerEventsCommandOSD"})) {
			$g_config_servers{$addr}{"PlayerEventsCommandOSD"}			= "";
		}
		if (!defined($g_config_servers{$addr}{"PlayerEventsCommandHint"})) {
			$g_config_servers{$addr}{"PlayerEventsCommandHint"}			= "";
		}
		if (!defined($g_config_servers{$addr}{"PlayerEventsAdminCommand"})) {
			$g_config_servers{$addr}{"PlayerEventsAdminCommand"}		= "";
		}
		if (!defined($g_config_servers{$addr}{"ShowStats"})) {
			$g_config_servers{$addr}{"ShowStats"}						= 1;
		}
		if (!defined($g_config_servers{$addr}{"AutoTeamBalance"})) {
			$g_config_servers{$addr}{"AutoTeamBalance"}					= 0;
		}
		if (!defined($g_config_servers{$addr}{"AutoBanRetry"})) {
			$g_config_servers{$addr}{"AutoBanRetry"}					= 0;
		}
		if (!defined($g_config_servers{$addr}{"TrackServerLoad"})) {
			$g_config_servers{$addr}{"TrackServerLoad"}					= 0;
		}
		if (!defined($g_config_servers{$addr}{"MinimumPlayersRank"})) {
			$g_config_servers{$addr}{"MinimumPlayersRank"}				= 0;
		}
		if (!defined($g_config_servers{$addr}{"Admins"})) {
			$g_config_servers{$addr}{"Admins"}							= "";
		}
		if (!defined($g_config_servers{$addr}{"SwitchAdmins"})) {
			$g_config_servers{$addr}{"SwitchAdmins"}					= 0;
		}
		if (!defined($g_config_servers{$addr}{"IgnoreBots"})) {
			$g_config_servers{$addr}{"IgnoreBots"}						= 1;
		}
		if (!defined($g_config_servers{$addr}{"SkillMode"})) {
			$g_config_servers{$addr}{"SkillMode"}						= 0;
		}
		if (!defined($g_config_servers{$addr}{"GameType"})) {
			$g_config_servers{$addr}{"GameType"}						= 0;
		}
		if (!defined($g_config_servers{$addr}{"BonusRoundTime"})) {
			$g_config_servers{$addr}{"BonusRoundTime"}					= 0;
		}
		if (!defined($g_config_servers{$addr}{"BonusRoundIgnore"})) {
			$g_config_servers{$addr}{"BonusRoundIgnore"}				= 0;
		}
		if (!defined($g_config_servers{$addr}{"Mod"})) {
			$g_config_servers{$addr}{"Mod"}								= "";
		}
		if (!defined($g_config_servers{$addr}{"EnablePublicCommands"})) {
			$g_config_servers{$addr}{"EnablePublicCommands"}			= 1;
		}
		if (!defined($g_config_servers{$addr}{"ConnectAnnounce"})) {
			# KTP policy: never inject rank/points connect messages into live
			# game chat. Missing per-server configuration must fail closed.
			$g_config_servers{$addr}{"ConnectAnnounce"}					= 0;
		}
		if (!defined($g_config_servers{$addr}{"UpdateHostname"})) {
			$g_config_servers{$addr}{"UpdateHostname"}					= 0;
		}
		if (!defined($g_config_servers{$addr}{"DefaultDisplayEvents"})) {
			$g_config_servers{$addr}{"DefaultDisplayEvents"}			= 1;
		}
	}

	&printEvent("CONFIG", "I have found the following server configs in database:", 1);
	while (my($addr, $server) = each(%g_config_servers)) {
		&printEvent("S_CONFIG", $addr, 1);
	}
	
	if ($g_geoip_binary > 0 && !defined($g_gi)) {
		my $geoipfile = "$opt_libdir/GeoLiteCity/GeoLite2-City.mmdb";
		if (-r $geoipfile) {
			eval "use GeoIP2::Database::Reader"; my $hasGeoIP = $@ ? 0 : 1;
			if ($hasGeoIP) {
				$g_gi = GeoIP2::Database::Reader->new(
						file    => $geoipfile,
						locales => [ 'en' ]
				);
			} else {
				&printEvent("ERROR", "GeoIP method set to binary file lookup but GeoIP2::Database::Reader module NOT FOUND", 1);
				$g_gi = undef;
			}
		} else {
			&printEvent("ERROR", "GeoIP method set to binary file lookup but $geoipfile NOT FOUND", 1);
			$g_gi = undef;
		}
	} elsif ($g_geoip_binary == 0 && defined($g_gi)) {
		$g_gi->close();
		$g_gi = undef;
	}
	&loadHostGroups();
}

# Read Config File

if ($opt_configfile && -r $opt_configfile) {
	$conf = ConfigReaderSimple->new($opt_configfile);
	$conf->parse();
	%directives = (
		"DBHost",					"db_host",
		"DBUsername",			"db_user",
		"DBPassword",			"db_pass",
		"DBName",					"db_name",
		"DBLowPriority",		"db_lowpriority",
		"BindIP",					"s_ip",
		"Port",						"s_port",
		"DebugLevel",			"g_debug",
		"CpanelHack",			"g_cpanelhack",
		"EventQueueSize",		"g_event_queue_size"
	);

	%directives_mysql = (
		"version",					"g_version",
		"MailTo",					"g_mailto",
		"MailPath",					"g_mailpath",
		"Mode",						"g_mode",
		"DeleteDays",				"g_deletedays",
		"UseTimestamp",				"g_timestamp",
		"DNSResolveIP",				"g_dns_resolveip",
		"DNSTimeout",				"g_dns_timeout",
		"RconIgnoreSelf",			"g_rcon_ignoreself",
		"Rcon",						"g_rcon",
		"RconRecord",				"g_rcon_record",
		"MinPlayers",				"g_minplayers",
		"SkillMaxChange",			"g_skill_maxchange",
		"SkillMinChange",			"g_skill_minchange",
		"PlayerMinKills",			"g_player_minkills",
		"AllowOnlyConfigServers",	"g_onlyconfig_servers",
		"TrackStatsTrend",			"g_track_stats_trend",
		"GlobalBanning",			"g_global_banning",
		"LogChat",					"g_log_chat",
		"LogChatAdmins",			"g_log_chat_admins",
		"GlobalChat",				"g_global_chat",
		"SkillRatioCap",			"g_skill_ratio_cap",
		"rankingtype",				"g_ranktype",
		"UseGeoIPBinary",			"g_geoip_binary",
		"Proxy_Key",				"proxy_key"
	);

#		"Servers",                "g_config_servers"
	&doConf($conf, %directives);

} else {
	print "-- Warning: unable to open configuration file '$opt_configfile'\n";
}

# Read Command Line Arguments

%copts = ();

GetOptions(
	"help|h"			=> \$copts{opt_help},
	"version|v"			=> \$copts{opt_version},
	"debug|d+"			=> \$copts{g_debug},
	"nodebug|n+"		=> \$copts{g_nodebug},
	"mode|m=s"			=> \$copts{g_mode},
	"configfile|c=s"	=> \$copts{configfile},
	"db-host=s"			=> \$copts{db_host},
	"db-name=s"			=> \$copts{db_name},
	"db-password=s"		=> \$copts{db_pass},
	"db-username=s"		=> \$copts{db_user},
	"dns-resolveip!"	=> \$copts{g_dns_resolveip},
	"dns-timeout=i"		=> \$copts{g_dns_timeout},
	"ip|i=s"			=> \$copts{s_ip},
	"port|p=i"			=> \$copts{s_port},
	"rcon!"				=> \$copts{g_rcon},
	"r"					=> \$copts{g_rcon},
	"stdin!"			=> \$copts{g_stdin},
	"s"					=> \$copts{g_stdin},
	"server-ip=s"		=> \$copts{g_server_ip},
	"server-port=i"		=> \$copts{g_server_port},
	"timestamp!"		=> \$copts{g_timestamp},
	"t"					=> \$copts{g_timestamp},
	"event-queue-size"  => \$copts{g_event_queue_size}
) or die($usage);


if ($configfile && -r $configfile) {
	$conf = '';
    $conf = ConfigReaderSimple->new($configfile);
    $conf->parse();
	&doConf($conf, %directives);
}

# these are set above, we then reload them to override values in the actual config
setOptionsConf(%copts);

if ($g_cpanelhack) {
	my $home_dir = $ENV{ HOME };
	my $base_module_dir = (-d "$home_dir/perl" ? "$home_dir/perl" : ( getpwuid($>) )[7] . '/perl/');
	unshift @INC, map { $base_module_dir . $_ } @INC;
}

eval {
  require Geo::IP::PurePerl;
};
import Geo::IP::PurePerl;

if ($opt_help) {
	print $usage;
	exit(0);
}

if ($opt_version) {
	&doConnect;
	my $result = &doQuery("
		SELECT
			value
		FROM
			hlstats_Options
		WHERE
			keyname='version'
	");

	if ($result->rows > 0) {
		$g_version = $result->fetchrow_array;
	}
	$result->finish;
	print "\nhlstats.pl (HLstatsX Community Edition) Version $g_version\n"
		. "Real-time player and clan rankings and statistics for Half-Life 2\n"
		. "Modified (C) 2008-20XX  Nicholas Hastings (nshastings@gmail.com)\n"
		. "Copyleft (L) 2007-2008  Malte Bayer\n"
		. "Modified (C) 2005-2007  Tobias Oetzel (Tobi@hlstatsx.com)\n"
		. "Original (C) 2001 by Simon Garner \n\n";
	
	print "Using ConfigReaderSimple module version $ConfigReaderSimple::VERSION\n";
	if ($g_rcon) {
		print "Using rcon module\n";
	}
	
	print "\nThis is free software; see the source for copying conditions.  There is NO\n"
		. "warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.\n\n";
	exit(0);
}

# Connect to the database

&doConnect;
&readDatabaseConfig;
&buildEventInsertData;

if ($g_mode ne "Normal" && $g_mode ne "LAN" && $g_mode ne "NameTrack") {
	$g_mode = "Normal";
}

$g_debug -= $g_nodebug;
$g_debug = 0 if ($g_debug < 0);


# Init Timestamp
my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time());
$ev_timestamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year+1900, $mon+1, $mday, $hour, $min, $sec);
$ev_unixtime  = time();
$ev_daemontime = $ev_unixtime;

# Startup

&printEvent("HLSTATSX", "HLstatsX:CE $g_version starting...", 1);

# Create the UDP & TCP socket

if ($g_stdin) {
	$g_rcon = 0;
	&printEvent("UDP", "UDP listen socket disabled, reading log data from STDIN.", 1);
	if (!$g_server_ip || !$g_server_port) {
		&printEvent("UDP", "ERROR: You must specify source of STDIN data using --server-ip and --server-port", 1);
		&printEvent("UDP", "Example: ./hlstats.pl --stdin --server-ip 12.34.56.78 --server-port 27015", 1);
		exit(255);
	} else {
		&printEvent("UDP", "All data from STDIN will be allocated to server '$g_server_ip:$g_server_port'.", 1);
		$s_peerhost = $g_server_ip;
		$s_peerport = $g_server_port;
		$s_addr = "$s_peerhost:$s_peerport";
	}
} else {
	if ($s_ip) { $ip = $s_ip . ":"; } else { $ip = "port "; }
	$s_socket = IO::Socket::INET->new(
		Proto=>"udp",
		LocalAddr=>"$s_ip",
		LocalPort=>"$s_port"
	) or die ("\nCan't setup UDP socket on $ip$s_port: $!\n");
	# Match net.core.rmem_max (25MB, set in /etc/sysctl.d/98-ktp-dataserver.conf).
	# Asking for 1MB was the actual drop: the ceiling was raised to 25MB and this
	# request never was, so the socket got 1MB on a box configured for 25 and the
	# ceiling looked like the fix while doing nothing.
	my $want_rcvbuf = 26214400;
	$s_socket->sockopt(SO_RCVBUF, $want_rcvbuf);
	my $actual_rcvbuf = $s_socket->sockopt(SO_RCVBUF);
	$s_select = IO::Select->new($s_socket);

	&printEvent("UDP", "Opening UDP listen socket on $ip$s_port ... ok", 1);
	&printEvent("UDP", "Socket receive buffer: " . int($actual_rcvbuf / 1024) . "KB", 1);

	# Linux silently clamps the request to net.core.rmem_max and reports back double
	# what it granted. Asking for a buffer and not getting it is exactly the condition
	# that loses log lines under concurrent servers, and nothing else reports it.
	if (($actual_rcvbuf / 2) < $want_rcvbuf) {
		&printEvent("UDP",
			"WARNING: asked for " . int($want_rcvbuf / 1024) . "KB of receive buffer but " .
			"the kernel granted " . int($actual_rcvbuf / 2 / 1024) . "KB. Raise " .
			"net.core.rmem_max -- under load this drops log lines with no other symptom.", 1);
	}
}

if ($g_track_stats_trend > 0) {
	&printEvent("HLSTATSX", "Tracking Trend of the stats are enabled", 1);
}

if ($g_global_banning > 0) {
	&printEvent("HLSTATSX", "Global Banning on all servers is enabled", 1);
}

&printEvent("HLSTATSX", "Maximum Skill Change on all servers are ".$g_skill_maxchange." points", 1);
&printEvent("HLSTATSX", "Minimum Skill Change on all servers are ".$g_skill_minchange." points", 1);
&printEvent("HLSTATSX", "Minimum Players Kills on all servers are ".$g_player_minkills." kills", 1);

if ($g_log_chat > 0) {
	&printEvent("HLSTATSX", "Players chat logging is enabled", 1);
	if ($g_log_chat_admins > 0) {
		&printEvent("HLSTATSX", "Admins chat logging is enabled", 1);
	}
}

if ($g_global_chat == 1) {
	&printEvent("HLSTATSX", "Broadcasting public chat to all players is enabled", 1);
} elsif ($g_global_chat == 2) {
	&printEvent("HLSTATSX", "Broadcasting public chat to admins is enabled", 1);
} else {
	&printEvent("HLSTATSX", "Broadcasting public chat is disabled", 1);
}

&printEvent("HLSTATSX", "Event queue size is set to ".$g_event_queue_size, 1);


%g_servers = ();

# KTP: Match context tracking for KTP Match Handler integration
# Stores match_id per server address for tagging events
%g_ktpMatchContext = ();

# KTP: Successful producer-time interval proofs are reusable. Damage is
# high-volume, so keep one bounded proof per exact server/match/half. Closed
# intervals prove their full range; open intervals prove only through DB NOW()
# and refresh on a later producer epoch. Failures are never cached.
%g_ktpProducerContextCache = ();
%g_ktpCaptureClockWarnings = ();

# KTP: actions seen in the log that resolve to no row in hlstats_Actions.
# {game/action} => count. Keyed so each distinct action warns once and then
# only tallies -- an objective-heavy map would otherwise flood the journal.
%g_ktpUnresolvedActions = ();

# KTP: write-path health, reported by the housekeeping loop. Retries that
# succeed are as interesting as failures: a rising retry count is the shape of
# a database connection dying under load, which otherwise looks like nothing.
$g_sql_error_count = 0;
$g_sql_retry_count = 0;
$g_ktp_lasthealth  = 0;

# KTP: In-memory accumulators for batching frag-related UPDATEs
# Flushed every 30s, on shutdown, and before match stats aggregation
%g_roles_accum = ();    # {game:code} => {kills => N, deaths => N}
%g_weapons_accum = ();  # {game:code} => {kills => N, headshots => N}
%g_maps_accum = ();     # {game:map}  => {kills => N, headshots => N}
%g_ktpScoreAccum = ();  # {match_id}{player_id}{half_num} => score total
$g_accum_lastflush = 0; # housekeeping-loop gate; see the flushAccumulators call site

&printEvent("HLSTATSX", "HLstatsX:CE is now running ($g_mode mode, debug level $g_debug)", 1);

$start_time    = time();
if ($g_stdin) {
  $g_timestamp       = 1;
  $start_parse_time  = time();
  $import_logs_count = 0;
  &printEvent("IMPORT", "Start importing logs. Every dot signs 500 parsed lines", 1, 1);
}

# Main data loop
$c = 0;

sub getLine
{
	if ($g_stdin) {
		return <STDIN>;
	} else {
		return 1;
	}
}


&execNonQuery("TRUNCATE TABLE hlstats_Livestats");
$timeout    = 0;
$s_output = "";
my ($proxy_s_peerhost, $proxy_s_peerport);
while ($loop = &getLine()) {

    my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time());
    $ev_timestamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year+1900, $mon+1, $mday, $hour, $min, $sec);
	$ev_unixtime  = time();
	$ev_daemontime = $ev_unixtime; #time()

	if ($g_stdin) {
		$s_output = $loop;
		if (($import_logs_count > 0) && ($import_logs_count % 500 == 0)) {
			$parse_time = $ev_unixtime - $start_parse_time;
			if ($parse_time == 0) {
				$parse_time++;
			}
			print ". [".($parse_time)." sec (".sprintf("%.3f", (500 / $parse_time)).")]\n";
			$start_parse_time = $ev_unixtime;
		}
	} else {
		# UDP mode: drain-then-process architecture
		# Drain phase: read all available packets into queue
		@_pkt_queue = ();
		if ($s_select->can_read(2)) {  # 2 second timeout for first packet
			while (scalar(@_pkt_queue) < 500) {
				my ($pkt_data, $pkt_peer);
				$pkt_peer = recv($s_socket, $pkt_data, 4096, 0);
				last if (!defined($pkt_peer) || length($pkt_data) == 0);
				my ($pkt_port, $pkt_iaddr) = sockaddr_in($pkt_peer);
				push @_pkt_queue, [$pkt_data, inet_ntoa($pkt_iaddr), $pkt_port];
				last unless $s_select->can_read(0);  # non-blocking check for more
			}
			if (scalar(@_pkt_queue) >= 500) {
				&printEvent("UDP", "Drain cap reached: 500 packets in single cycle, possible burst", 1);
			}
			$timeout = 0;
		} else {
			$timeout++;
			if ($timeout % 60 == 0) {
				&printEvent("HLSTATSX", "No data since 120 seconds");
			}
		}
	}

	# Process phase: iterate drained packets (UDP) or single pass (STDIN)
	my $_pkt_count = $g_stdin ? 1 : scalar(@_pkt_queue);
	for (my $_pi = 0; $_pi < $_pkt_count; $_pi++) {
		# For UDP mode, set per-packet variables from drained queue
		if (!$g_stdin) {
			my $_pkt = $_pkt_queue[$_pi];
			$s_output = decode('utf8', $_pkt->[0]);
			$s_peerhost = $_pkt->[1];
			$s_peerport = $_pkt->[2];
			$s_addr = "$s_peerhost:$s_peerport";

			if (($s_output =~ /^.*PROXY Key=(.+?) (.*)PROXY.+/) && $proxy_key ne "") {
				$rproxy_key = $1;
				$s_addr = $2;

				if ($s_addr ne "") {
					($s_peerhost, $s_peerport) = split(/:/, $s_addr);
				}

				$proxy_s_peerhost = $_pkt->[1];
				$proxy_s_peerport = $_pkt->[2];
				&printEvent("PROXY", "Detected proxy call from $proxy_s_peerhost:$proxy_s_peerport") if ($g_debug > 2);

				if ($proxy_key eq $rproxy_key) {
					$s_output =~ s/PROXY.*PROXY //;
					if ($s_output =~ /^C;HEARTBEAT;/) {
						&printEvent("PROXY", "Heartbeat request from $proxy_s_peerhost:$proxy_s_peerport");
					} elsif ($s_output =~ /^C;RELOAD;/) {
						&printEvent("PROXY", "Reload request from $proxy_s_peerhost:$proxy_s_peerport");
					} elsif ($s_output =~ /^C;KILL;/) {
						&printEvent("PROXY", "Kill request from $proxy_s_peerhost:$proxy_s_peerport");
					} else {
						&printEvent("PROXY", $s_output);
					}
				} else {
					&printEvent("PROXY", "proxy_key mismatch, dropping package");
					&printEvent("PROXY", $s_output) if ($g_debug > 2);
					$s_output = "";
					next;
				}
			} else {
				# Reset the proxy stuff
				$rproxy_key = "";
				$proxy_s_peerhost = "";
				$proxy_s_peerport = "";
			}
		}

	if ($timeout == 0) {
		my ($address, $port);
		my @data = split ";", $s_output;
		$cmd = $data[0];
		if ($cmd eq "C" && ($s_peerhost eq "127.0.0.1" || (($proxy_key eq $rproxy_key) && $proxy_key ne ""))) {
			&printEvent("CONTROL", "Command received: ".$data[1], 1);
			if ($proxy_s_peerhost ne "" && $proxy_s_peerport ne "") {
				$address = $proxy_s_peerhost;
				$port = $proxy_s_peerport;
			} else {
				$address = $s_peerhost;
				$port = $s_peerport;
			}

			$s_addr = "$address:$port";

			my $dest = sockaddr_in($port, inet_aton($address));
			if ($data[1] eq "HEARTBEAT") {
				my $msg = "Heartbeat OK";
				$bytes = send($::s_socket, $msg, 0, $dest);
				&printEvent("CONTROL", "Send heartbeat status to frontend at '$address:$port'", 1);
			} else {
				my $msg = "OK, EXECUTING COMMAND: ".$data[1];
				$bytes = send($::s_socket, $msg, 0, $dest);
				&printEvent("CONTROL", "Sent $bytes bytes to frontend at '$address:$port'", 1);
			}

			if ($data[1] eq "RELOAD") {
				&printEvent("CONTROL", "Re-Reading Configuration by request from Frontend...", 1);
				&reloadConfiguration;
			} 

			if ($data[1] eq "KILL") {
				&printEvent("CONTROL", "SHUTTING DOWN SCRIPT", 1);
				&flushAll;
				die "Exit script by request";
			} 
			
			next;
		}  
		$s_output =~ s/[\r\n\0]//g;	# remove naughty characters
		$s_output =~ s/\[No.C-D\]//g;	# remove [No C-D] tag
		$s_output =~ s/\[OLD.C-D\]//g;	# remove [OLD C-D] tag
		$s_output =~ s/\[NOCL\]//g;	# remove [NOCL] tag

		# Get the server info, if we know the server, otherwise ignore the data
		if (!defined($g_servers{$s_addr})) {
			if (($g_onlyconfig_servers == 1) && (!defined($g_config_servers{$s_addr}))) {
				# HELLRAISER disabled this for testing
				&printEvent(997, "NOT ALLOWED SERVER: " . $s_output);
				next;
			} elsif (!defined($g_config_servers{$s_addr})) { # create std cfg.
				my %std_cfg;
				$std_cfg{"MinPlayers"}						= 6;
				$std_cfg{"HLStatsURL"}						= "";
				$std_cfg{"DisplayResultsInBrowser"}			= 0;
				$std_cfg{"BroadCastEvents"}					= 0;
				$std_cfg{"BroadCastPlayerActions"}			= 0;
				$std_cfg{"BroadCastEventsCommand"}			= "say";
				$std_cfg{"BroadCastEventsCommandAnnounce"}	= "say";
				$std_cfg{"PlayerEvents"}					= 1;
				$std_cfg{"PlayerEventsCommand"}				= "say";
				$std_cfg{"PlayerEventsCommandOSD"}			= "";
				$std_cfg{"PlayerEventsCommandHint"}			= "";
				$std_cfg{"PlayerEventsAdminCommand"}		= "";
				$std_cfg{"ShowStats"}						= 1;
				$std_cfg{"TKPenalty"}						= 50;
				$std_cfg{"SuicidePenalty"}					= 5;
				$std_cfg{"AutoTeamBalance"}					= 0;
				$std_cfg{"AutobanRetry"}					= 0;
				$std_cfg{"TrackServerLoad"}					= 0;
				$std_cfg{"MinimumPlayersRank"}				= 0;
				$std_cfg{"EnablePublicCommands"}			= 1;
				$std_cfg{"Admins"}							= "";
				$std_cfg{"SwitchAdmins"}					= 0;
				$std_cfg{"IgnoreBots"}						= 1;
				$std_cfg{"SkillMode"}						= 0;
				$std_cfg{"GameType"}						= 0;
				$std_cfg{"Mod"}								= "";
				$std_cfg{"BonusRoundIgnore"}				= 0;
				$std_cfg{"BonusRoundTime"}					= 20;
				$std_cfg{"UpdateHostname"}					= 0;
				# Unknown servers inherit the same no-chat-announcement policy.
				$std_cfg{"ConnectAnnounce"}					= 0;
				$std_cfg{"DefaultDisplayEvents"}			= 1;
				%{$g_config_servers{$s_addr}}				= %std_cfg;
				&printEvent("CFG", "Created default config for unknown server [$s_addr]");
				&printEvent("DETECT", "New server with game: " . &getServerMod($s_peerhost, $s_peerport));
			}
			
			if ($g_config_servers{$s_addr}) {
				my $tempsrv = &getServer($s_peerhost, $s_peerport);
				next if ($tempsrv == 0);
				$g_servers{$s_addr} = $tempsrv;
				my %s_cfg = %{$g_config_servers{$s_addr}};
				$g_servers{$s_addr}->set("minplayers", $s_cfg{"MinPlayers"});
				$g_servers{$s_addr}->set("hlstats_url", $s_cfg{"HLStatsURL"});
				if ($s_cfg{"DisplayResultsInBrowser"} > 0) {
					$g_servers{$s_addr}->set("use_browser",  1);
					&printEvent("SERVER", "Query results will displayed in valve browser", 1); 
				} else { 
					$g_servers{$s_addr}->set("use_browser",  0);
					&printEvent("SERVER", "Query results will not displayed in valve browser", 1); 
				}
				if ($s_cfg{"ShowStats"} == 1) {
					$g_servers{$s_addr}->set("show_stats",  1);
					&printEvent("SERVER", "Showing stats is enabled", 1); 
				} else {
					$g_servers{$s_addr}->set("show_stats",  0);
					&printEvent("SERVER", "Showing stats is disabled", 1); 
				}
				if ($s_cfg{"BroadCastEvents"} == 1) {  
					$g_servers{$s_addr}->set("broadcasting_events",  1);
					$g_servers{$s_addr}->set("broadcasting_player_actions",  $s_cfg{"BroadCastPlayerActions"});
					$g_servers{$s_addr}->set("broadcasting_command", $s_cfg{"BroadCastEventsCommand"});
					if ($s_cfg{"BroadCastEventsCommandAnnounce"} eq "ma_hlx_csay") {
						$s_cfg{"BroadCastEventsCommandAnnounce"} = $s_cfg{"BroadCastEventsCommandAnnounce"}." #all";
					}
					$g_servers{$s_addr}->set("broadcasting_command_announce", $s_cfg{"BroadCastEventsCommandAnnounce"});

					&printEvent("SERVER", "Broadcasting Live-Events with \"".$s_cfg{"BroadCastEventsCommand"}."\" is enabled", 1); 
					if ($s_cfg{"BroadCastEventsCommandAnnounce"} ne "") {
						&printEvent("SERVER", "Broadcasting Announcements with \"".$s_cfg{"BroadCastEventsCommandAnnounce"}."\" is enabled", 1); 
					}  
				} else {
					$g_servers{$s_addr}->set("broadcasting_events",               0);
					&printEvent("SERVER", "Broadcasting Live-Events is disabled", 1); 
				}
				if ($s_cfg{"PlayerEvents"} == 1) {
					$g_servers{$s_addr}->set("player_events",  1);
					$g_servers{$s_addr}->set("player_command", $s_cfg{"PlayerEventsCommand"});
					$g_servers{$s_addr}->set("player_command_osd", $s_cfg{"PlayerEventsCommandOSD"});
					$g_servers{$s_addr}->set("player_command_hint", $s_cfg{"PlayerEventsCommandHint"});
					$g_servers{$s_addr}->set("player_admin_command", $s_cfg{"PlayerEventsAdminCommand"});
					&printEvent("SERVER", "Player Event-Handler with \"".$s_cfg{"PlayerEventsCommand"}."\" is enabled", 1); 
					if ($s_cfg{"PlayerEventsCommandOSD"} ne "") {
						&printEvent("SERVER", "Displaying amx style menu with \"".$s_cfg{"PlayerEventsCommandOSD"}."\" is enabled", 1); 
					}
				} else {
					$g_servers{$s_addr}->set("player_events",                 0);
					&printEvent("SERVER", "Player Event-Handler is disabled", 1); 
				}
				if ($s_cfg{"DefaultDisplayEvents"} > 0) {
					$g_servers{$s_addr}->set("default_display_events", "1");
					&printEvent("SERVER", "New Players defaulting to show event messages", 1);
				} else {
					$g_servers{$s_addr}->set("default_display_events", "0");
					&printEvent("SERVER", "New Players defaulting to NOT show event messages", 1);
				}
				if ($s_cfg{"TrackServerLoad"} > 0) {
					$g_servers{$s_addr}->set("track_server_load", "1");
					&printEvent("SERVER", "Tracking server load is enabled", 1);
				} else {
					$g_servers{$s_addr}->set("track_server_load", "0");
					&printEvent("SERVER", "Tracking server load is disabled", 1);
				}

				if ($s_cfg{"TKPenalty"} > 0) {
					$g_servers{$s_addr}->set("tk_penalty", $s_cfg{"TKPenalty"});
					&printEvent("SERVER", "Penalty team kills with ".$s_cfg{"TKPenalty"}." points", 1);
				}  
				if ($s_cfg{"SuicidePenalty"} > 0) {
					$g_servers{$s_addr}->set("suicide_penalty", $s_cfg{"SuicidePenalty"});
					&printEvent("SERVER", "Penalty suicides with ".$s_cfg{"SuicidePenalty"}." points", 1);
				}  
				if ($s_cfg{"BonusRoundTime"} > 0) {
					$g_servers{$s_addr}->set("bonusroundtime", $s_cfg{"BonusRoundTime"});
					&printEvent("SERVER", "Bonus Round time set to: ".$s_cfg{"BonusRoundTime"}, 1);
				} 
				if ($s_cfg{"BonusRoundIgnore"} > 0) {
					$g_servers{$s_addr}->set("bonusroundignore", $s_cfg{"BonusRoundIgnore"});
					&printEvent("SERVER", "Bonus Round is being ignored. Length: (".$s_cfg{"BonusRoundTime"}.")", 1);
				}
				if ($s_cfg{"AutoTeamBalance"} > 0) {
					$g_servers{$s_addr}->set("ba_enabled", "1");
					&printEvent("TEAMS", "Auto-Team-Balancing is enabled", 1);
				} else {
					$g_servers{$s_addr}->set("ba_enabled", "0");
					&printEvent("TEAMS", "Auto-Team-Balancing is disabled", 1);
				}
				if ($s_cfg{"AutoBanRetry"} > 0) {
					$g_servers{$s_addr}->set("auto_ban", "1");
					&printEvent("TEAMS", "Auto-Retry-Banning is enabled", 1);
				} else {
					$g_servers{$s_addr}->set("auto_ban", "0");
					&printEvent("TEAMS", "Auto-Retry-Banning is disabled", 1);
				}
				
				if ($s_cfg{"MinimumPlayersRank"} > 0) {
					$g_servers{$s_addr}->set("min_players_rank", $s_cfg{"MinimumPlayersRank"});
					&printEvent("SERVER", "Requires minimum players rank is enabled [MinPos:".$s_cfg{"MinimumPlayersRank"}."]", 1);
				} else {
					$g_servers{$s_addr}->set("min_players_rank", "0");
					&printEvent("SERVER", "Requires minimum players rank is disabled", 1);
				}
				
				if ($s_cfg{"EnablePublicCommands"} > 0) {
					$g_servers{$s_addr}->set("public_commands", $s_cfg{"EnablePublicCommands"});
					&printEvent("SERVER", "Public chat commands are enabled", 1);
				} else {
					$g_servers{$s_addr}->set("public_commands", "0");
					&printEvent("SERVER", "Public chat commands are disabled", 1);
				}

				if ($s_cfg{"Admins"} ne "") {
					@{$g_servers{$s_addr}->{admins}} = split(/,/, $s_cfg{"Admins"});
					foreach(@{$g_servers{$s_addr}->{admins}})
					{
						$_ =~ s/^STEAM_[0-9]+?\://i;
					}
					&printEvent("SERVER", "Admins: ".$s_cfg{"Admins"}, 1);
				}

				if ($s_cfg{"SwitchAdmins"} > 0) {
					$g_servers{$s_addr}->set("switch_admins", "1");
					&printEvent("TEAMS", "Switching Admins on Auto-Team-Balance is enabled", 1);
				} else {
					$g_servers{$s_addr}->set("switch_admins", "0");
					&printEvent("TEAMS", "Switching Admins on Auto-Team-Balance is disabled", 1);
				}
				
				if ($s_cfg{"IgnoreBots"} > 0) {
					$g_servers{$s_addr}->set("ignore_bots", "1");
					&printEvent("SERVER", "Ignoring bots is enabled", 1);
				} else {
					$g_servers{$s_addr}->set("ignore_bots", "0");
					&printEvent("SERVER", "Ignoring bots is disabled", 1);
				}
				$g_servers{$s_addr}->set("skill_mode", $s_cfg{"SkillMode"});
				&printEvent("SERVER", "Using skill mode ".$s_cfg{"SkillMode"}, 1);
				
				if ($s_cfg{"GameType"} == 1) {
					$g_servers{$s_addr}->set("game_type", $s_cfg{"GameType"});
					&printEvent("SERVER", "Game type: Counter-Strike: Source - Deathmatch", 1);
				} else {
					$g_servers{$s_addr}->set("game_type", "0");
					&printEvent("SERVER", "Game type: Normal", 1);
				}

				$g_servers{$s_addr}->set("mod", $s_cfg{"Mod"});
				
				if ($s_cfg{"Mod"} ne "") {
					&printEvent("SERVER", "Using plugin ".$s_cfg{"Mod"}." for internal functions!", 1);
				}
				if ($s_cfg{"ConnectAnnounce"} == 1) {
					$g_servers{$s_addr}->set("connect_announce", $s_cfg{"ConnectAnnounce"});
					&printEvent("SERVER", "Connect Announce is enabled", 1);
				} else {
					$g_servers{$s_addr}->set("connect_announce", "0");
					&printEvent("SERVER", "Connect Announce is disabled", 1);
				}
				if ($s_cfg{"UpdateHostname"} == 1) {
					$g_servers{$s_addr}->set("update_hostname", $s_cfg{"UpdateHostname"});
					&printEvent("SERVER", "Auto-updating hostname is enabled", 1);
				} else {
					$g_servers{$s_addr}->set("update_hostname", "0");
					&printEvent("SERVER", "Auto-updating hostname is disabled", 1);
				}
				$g_servers{$s_addr}->get_game_mod_opts();
			}
		}

		if (!$g_servers{$s_addr}->{"srv_players"})
		{
			$g_servers{$s_addr}->{"srv_players"} = ();
			%g_players=();
		}
		else
		{	
			%g_players=%{$g_servers{$s_addr}->{"srv_players"}};
		}
		
		# Get the datestamp (or complain)
		#if ($s_output =~ s/^.*L (\d\d)\/(\d\d)\/(\d{4}) - (\d\d):(\d\d):(\d\d):\s*//)
		
		#$is_streamed = 0;
		#$test_for_date = 0;
		#$is_streamed = ($s_output !~ m/^L\s*/);

		#if ( !$is_streamed ) {
		# $test_for_date = ($s_output =~ s/^L (\d\d)\/(\d\d)\/(\d{4}) - (\d\d):(\d\d):(\d\d):\s*//);
		#} else {
		# $test_for_date = ($s_output =~ s/^\S*L (\d\d)\/(\d\d)\/(\d{4}) - (\d\d):(\d\d):(\d\d):\s*//);
		#}
		
		#if ($test_for_date)
		
		# EXPLOIT FIX
		
		if ($s_output =~ s/^(?:.*?)?L (\d\d)\/(\d\d)\/(\d{4}) - (\d\d):(\d\d):(\d\d):\s*//) {
			$ev_month = $1;
			$ev_day   = $2;
			$ev_year  = $3;
			$ev_hour  = $4;
			$ev_min   = $5;
			$ev_sec   = $6;
			$ev_time  = "$ev_hour:$ev_min:$ev_sec";
			$ev_remotetime  = timelocal($ev_sec,$ev_min,$ev_hour,$ev_day,$ev_month-1,$ev_year);
			
			if ($g_timestamp) {
				$ev_timestamp = "$ev_year-$ev_month-$ev_day $ev_time";
				$ev_unixtime  = $ev_remotetime;
				if ($g_stdin)
				{
					$ev_daemontime = $ev_unixtime;
				}
			}
		} else {
			&printEvent(998, "MALFORMED DATA: " . $s_output);
			next;
		}
		
		# KTP DEBUG: Trace all lines containing KTP_MATCH
		if ($s_output =~ /KTP_MATCH/) {
			&printEvent("KTP_DEBUG", "RAW LINE RECEIVED: '$s_output'", 1);
		}

		if ($g_debug >= 4) {
			print $s_addr.": \"".$s_output."\"\n";
		}
		
		if (($g_stdin == 0) && ($g_servers{$s_addr}->{last_event} > 0) && ( ($ev_unixtime - $g_servers{$s_addr}->{last_event}) > 299) ) {
			$g_servers{$s_addr}->set("map", "");
			$g_servers{$s_addr}->get_map();
		}
		
		$g_servers{$s_addr}->set("last_event", $ev_unixtime);

		# Now we parse the events.
		
		my $ev_type   = 0;
		my $ev_status = "";
		my $ev_team   = "";
		my $ev_player = 0;
		my $ev_verb   = "";
		my $ev_obj_a  = "";
		my $ev_obj_b  = "";
		my $ev_obj_c  = "";
		my $ev_properties = "";
		my %ev_properties = ();
		my %ev_player = ();
	
		# pvkii parrot log lines also fit the death line parsing
		if ($g_servers{$s_addr}->{play_game} == PVKII()
			&& $s_output =~ /^
				"(.+?(?:<[^>]*>){3})"		# player string
				\s[a-z]{6}\s				# 'killed'
				"npc_parrot<.+?>"			# parrot string
				\s[a-z]{5}\s[a-z]{2}\s		# 'owned by'
				"(.+?(?:<[^>]*>){3})"		# owner string
				\s[a-z]{4}\s				# 'with'
				"([^"]*)"				#weapon
				(.*)					#properties
				/x)
		{
			$ev_player = $1; # player
			$ev_obj_b  = $2; # victim
			$ev_obj_c  = $3; # weapon
			$ev_properties = $4;
			%ev_properties_hash = &getProperties($ev_properties);
			
			my $playerinfo = &getPlayerInfo($ev_player, 1);
			my $victiminfo = &getPlayerInfo($ev_obj_b, 1);
			$ev_type = 10;

			if ($playerinfo) {
				if ($victiminfo) {
					$ev_status = &doEvent_PlayerPlayerAction(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$victiminfo->{"userid"},
						$victiminfo->{"uniqueid"},
						"killed_parrot",
						undef,
						undef,
						undef,
						undef,
						undef,
						undef,
						&getProperties($ev_properties)
					);
				}

				$ev_type = 11;
				
				$ev_status = &doEvent_PlayerAction(
					$playerinfo->{"userid"},
					$playerinfo->{"uniqueid"},
					"killed_parrot",
					undef,
					undef,
					undef,
					&getProperties($ev_properties)
				);
			}
		} elsif ($s_output =~ /^
				(?:\(DEATH\))?		# l4d prefix, such as (DEATH) or (INCAP)
				"(.+?(?:<.+?>)*?
				(?:<setpos_exact\s(-?\d+?\.\d\d)\s(-?\d+?\.\d\d)\s(-?\d+?\.\d\d);[^"]*)?
				)"						# player string with or without l4d-style location coords
				(?:\s\[(-?\d+)\s(-?\d+)\s(-?\d+)\])?
				\skilled\s			# verb (ex. attacked, killed, triggered)
				"(.+?(?:<.+?>)*?
				(?:<setpos_exact\s(-?\d+?\.\d\d)\s(-?\d+?\.\d\d)\s(-?\d+?\.\d\d);[^"]*)?
				)"						# player string as above or action name
				(?:\s\[(-?\d+)\s(-?\d+)\s(-?\d+)\])?
				\swith\s				# (ex. with, against)
				"([^"]*)"
				(.*)					#properties
				/x)
		{

			# Prototype: "player" verb "obj_a" ?... "obj_b"[properties]
			# Matches:
			#  8. Kills
			
			$ev_player = $1;
			$ev_Xcoord = $2; # attacker/player coords (L4D)
			$ev_Ycoord = $3;
			$ev_Zcoord = $4;
			if( !defined($ev_Xcoord) ) {
				# if we didn't get L4D style, overwrite with CSGO style (which we may still not have)
				$ev_Xcoord = $5;
				$ev_Ycoord = $6;
				$ev_Zcoord = $7;
			}
			$ev_obj_a  = $8; # victim
			$ev_XcoordKV = $9; # kill victim coords (L4D)
			$ev_YcoordKV = $10;
			$ev_ZcoordKV = $11;
			if( !defined($ev_XcoordKV) ) {
				$ev_XcoordKV = $12; # kill victim coords (CSGO)
				$ev_YcoordKV = $13;
				$ev_ZcoordKV = $14;
			}
			$ev_obj_b  = $15; # weapon
			$ev_properties = $16;
			%ev_properties_hash = &getProperties($ev_properties);
			
			my $killerinfo = &getPlayerInfo($ev_player, 1);
			my $victiminfo = &getPlayerInfo($ev_obj_a, 1);
			$ev_type = 8;
			
			$headshot = 0;
			if ($ev_properties =~ m/headshot/) {
				$headshot = 1;
			}
			
			if ($killerinfo && $victiminfo) {
				my $killerId       = $killerinfo->{"userid"};
				my $killerUniqueId = $killerinfo->{"uniqueid"};
				my $killer         = lookupPlayer($s_addr, $killerId, $killerUniqueId);
				
				# octo
				if($killer->{role} eq "scout") {
					$ev_status = &doEvent_PlayerAction(
						$killerinfo->{"userid"},
						$killerinfo->{"uniqueid"},
						"kill_as_scout",
						"kill_as_scout"
					);
				}
				if($killer->{role} eq "spy") {
					$ev_status = &doEvent_PlayerAction(
						$killerinfo->{"userid"},
						$killerinfo->{"uniqueid"},
						"kill_as_spy",
						"kill_as_spy"
					);
				}

				my $victimId       = $victiminfo->{"userid"};
				my $victimUniqueId = $victiminfo->{"uniqueid"};
				my $victim         = lookupPlayer($s_addr, $victimId, $victimUniqueId);

				$ev_status = &doEvent_Frag(
					$killerinfo->{"userid"},
					$killerinfo->{"uniqueid"},
					$victiminfo->{"userid"},
					$victiminfo->{"uniqueid"},
					$ev_obj_b,
					$headshot,
					$ev_Xcoord,
					$ev_Ycoord,
					$ev_Zcoord,
					$ev_XcoordKV,
					$ev_YcoordKV,
					$ev_ZcoordKV,
					%ev_properties_hash
				);
			} 
		} elsif ($g_servers{$s_addr}->{play_game} == L4D() && $s_output =~ /^
				\(INCAP\)		# l4d prefix, such as (DEATH) or (INCAP)
				"(.+?(?:<.+?>)*?
				<setpos_exact\s(-?\d+?\.\d\d)\s(-?\d+?\.\d\d)\s(-?\d+?\.\d\d);[^"]*
				)"						# player string with or without l4d-style location coords
				\swas\sincapped\sby\s			# verb (ex. attacked, killed, triggered)
				"(.+?(?:<.+?>)*?
				<setpos_exact\s(-?\d+?\.\d\d)\s(-?\d+?\.\d\d)\s(-?\d+?\.\d\d);[^"]*
				)"						# player string as above or action name
				\swith\s				# (ex. with, against)
				"([^"]*)"					# weapon name
				(.*)					#properties
				/x)
		{
			#  800. L4D Incapacitation
			
			$ev_player = $1;
			$ev_l4dXcoord = $2; # attacker/player coords (L4D)
			$ev_l4dYcoord = $3;
			$ev_l4dZcoord = $4;
			$ev_obj_a  = $5; # victim
			$ev_l4dXcoordKV = $6; # kill victim coords (L4D)
			$ev_l4dYcoordKV = $7;
			$ev_l4dZcoordKV = $8;
			$ev_obj_b  = $9; # weapon
			$ev_properties = $10;
			%ev_properties_hash = &getProperties($ev_properties);
			
			# reverse killer/victim (x was incapped by y = y killed x)
			my $killerinfo = &getPlayerInfo($ev_obj_a, 1);
			my $victiminfo = &getPlayerInfo($ev_player, 1);
			
			if ($victiminfo->{team} eq "Infected") {
				$victiminfo = undef;
			}
			$ev_type = 800;
							
			$headshot = 0;
			if ($ev_properties =~ m/headshot/) {
				$headshot = 1;
			}
			if ($killerinfo && $victiminfo) {
				my $killerId       = $killerinfo->{"userid"};
				my $killerUniqueId = $killerinfo->{"uniqueid"};
				my $killer         = lookupPlayer($s_addr, $killerId, $killerUniqueId);

				my $victimId       = $victiminfo->{"userid"};
				my $victimUniqueId = $victiminfo->{"uniqueid"};
				my $victim         = lookupPlayer($s_addr, $victimId, $victimUniqueId);

				$ev_status = &doEvent_Frag(
					$killerinfo->{"userid"},
					$killerinfo->{"uniqueid"},
					$victiminfo->{"userid"},
					$victiminfo->{"uniqueid"},
					$ev_obj_b,
					$headshot,
					$ev_l4dXcoord,
					$ev_l4dYcoord,
					$ev_l4dZcoord,
					$ev_l4dXcoordKV,
					$ev_l4dYcoordKV,
					$ev_l4dZcoordKV,
					&getProperties($ev_properties)
				);
			}
		} elsif ($g_servers{$s_addr}->{play_game} == L4D() && $s_output =~ /^\(TONGUE\)\sTongue\sgrab\sstarting\.\s+Smoker:"(.+?(?:<.+?>)*?(?:|<setpos_exact ((?:|-)\d+?\.\d\d) ((?:|-)\d+?\.\d\d) ((?:|-)\d+?\.\d\d);.*?))"\.\s+Victim:"(.+?(?:<.+?>)*?(?:|<setpos_exact ((?:|-)\d+?\.\d\d) ((?:|-)\d+?\.\d\d) ((?:|-)\d+?\.\d\d);.*?))".*/) {
			# Prototype: (TONGUE) Tongue grab starting.  Smoker:"player". Victim:"victim".
			# Matches:
			# 11. Player Action
			
			$ev_player = $1;
			$ev_l4dXcoord = $2;
			$ev_l4dYcoord = $3;
			$ev_l4dZcoord = $4;
			$ev_victim = $5;
			$ev_l4dXcoordV = $6;
			$ev_l4dYcoordV = $7;
			$ev_l4dZcoordV = $8;
			
			$playerinfo = &getPlayerInfo($ev_player, 1);
			$victiminfo = &getPlayerInfo($ev_victim, 1);

			$ev_type = 11;
				
			if ($playerinfo) {
				$ev_status = &doEvent_PlayerAction(
					$playerinfo->{"userid"},
					$playerinfo->{"uniqueid"},
					"tongue_grab"
				);
			}
			if ($playerinfo && $victiminfo) {
					$ev_status = &doEvent_PlayerPlayerAction(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$victiminfo->{"userid"},
						$victiminfo->{"uniqueid"},
						"tongue_grab",
						$ev_l4dXcoord,
						$ev_l4dYcoord,
						$ev_l4dZcoord,
						$ev_l4dXcoordV,
						$ev_l4dYcoordV,
						$ev_l4dZcoordV
					);
			}
		} elsif ($s_output =~ /^
				"(.+?(?:<.+?>)*?
				)"						# player string
				\s(triggered(?:\sa)?)\s			# verb (ex. attacked, killed, triggered)
				"(.+?(?:<.+?>)*?
				)"						# player string as above or action name
				\s[a-zA-Z]+\s				# (ex. with, against)
				"(.+?(?:<.+?>)*?
				)"						# player string as above or weapon name
				(?:\s[a-zA-Z]+\s"(.+?)")?	# weapon name on plyrplyr actions
				(.*)					#properties
				/x)
		{			
		
			# 10. Player-Player Actions
			
			# no l4d/2 actions are logged with the locations (in fact, very few are logged period) so the l4d/2 location parsing can be skipped
			
			$ev_player = $1;
			$ev_verb   = $2; # triggered or triggered a
			$ev_obj_a  = $3; # action
			$ev_obj_b  = $4; # victim
			$ev_obj_c  = $5; # weapon (optional)
			$ev_properties = $6;
			%ev_properties_hash = &getProperties($ev_properties);
			

			if ($ev_verb eq "triggered") {  # it's either 'triggered' or 'triggered a'
				# KTP capture markers can sit in the AMXX/log buffers across a
				# reconnect. Resolve their stable player ids without getPlayerInfo(),
				# whose supposedly read-only mode can disconnect a newer userid.
				my ($ktp_actor_identity, $ktp_victim_identity,
					$ktp_actor_player_id, $ktp_victim_player_id);
				if ($ev_obj_a =~ /^(?:assist|frag_context|damage|headshot_kill)$/) {
					$ktp_actor_identity = &ktpParsePlayerIdentity($ev_player);
					$ktp_victim_identity = &ktpParsePlayerIdentity($ev_obj_b);
					$ktp_actor_player_id = &ktpResolvePlayerIdentity($ktp_actor_identity);
					$ktp_victim_player_id = &ktpResolvePlayerIdentity($ktp_victim_identity);
				}

				# Keep the existing generic assist action/rating-neutral path below,
				# and independently persist a canonical analytics row. Pure identity
				# parsing prevents a buffered marker from mutating reconnect state.
				if ($ev_obj_a eq "assist" &&
					defined($ev_properties_hash{"matchid"}) &&
					$ev_properties_hash{"matchid"} ne "-") {
					if ($ktp_actor_player_id && $ktp_victim_player_id) {
						&doEvent_KTPAssist(
							$ktp_actor_player_id, $ktp_victim_player_id,
							$ev_properties_hash{"matchid"},
							$ev_properties_hash{"half"},
							$ev_properties_hash{"event_epoch"},
							$ev_properties_hash{"game_time"},
							$ev_properties_hash{"assister_position"},
							$ev_properties_hash{"victim_position"});
					}
				}

				if ($ev_obj_a eq "headshot_kill") {
					# KTP: Headshot kill marker from stats_logging.sma
					# Fired immediately after the engine's kill log line for headshot kills.
					# We flush the frag queue then UPDATE the most recent matching frag to headshot=1.
					# ev_obj_b = victim player string, ev_obj_c = weapon
					$ev_type = 900;  # KTP headshot marker

					if ($ktp_actor_player_id && $ktp_victim_player_id) {
							# Flush pending frags so the kill is in the DB
							flushEventTable("Frags");

							# Time-bounded like frag_context below (dropped UDP lines).
							# Must NOT set frag_context_recorded -- that flag means the
							# context columns are real, and this marker collects none.
							# headshot is the claim guard. The insert-time parser at :2650 also
							# writes it, on a substring match over the raw property tail; DoD kill
							# lines carry no such property, so it never fires here. If a future
							# build appends frag properties to the kill line, this guard mis-targets.
							# FIFO, not newest-first: the emitting build buffers this marker for seconds
							# while kill lines arrive immediately, so "newest unclaimed" is routinely a
							# later kill. Still approximate -- no producer clock reaches this branch.
							my $hs_weapon = $ev_obj_c || "";
							my $hs_rv = &execNonQuery("
								UPDATE hlstats_Events_Frags
								SET headshot = 1
								WHERE serverId = ".$g_servers{$s_addr}->{'id'}."
								AND killerId = ".int($ktp_actor_player_id)."
								AND victimId = ".int($ktp_victim_player_id)."
								AND weapon = '".quoteSQL($hs_weapon)."'
								AND headshot = 0
								AND frag_context_recorded = 0
								AND eventTime >= FROM_UNIXTIME(".($ev_unixtime - 10).")
								ORDER BY id ASC
								LIMIT 1
							");
							if (defined($hs_rv) && $hs_rv == 0) {
								&printEvent("KTP_NO_ROW_MATCHED", "headshot_kill: no uncontextualized frag within 10s for killer=".$ktp_actor_player_id." victim=".$ktp_victim_player_id." weapon=$hs_weapon", 1, 1);
							}
							$ev_status = "Headshot marked for ".$ktp_actor_identity->{"uniqueid"}." -> ".$ktp_victim_identity->{"uniqueid"}." with $hs_weapon";
					}
				} elsif ($ev_obj_a eq "frag_context") {
					# KTP: Frag context marker from ktp_stats_capture.inc, fired on
					# EVERY kill. It supersedes headshot_kill in the plugin SOURCE only --
					# instances still on the older stats_logging build emit headshot_kill
					# and never this, so the branch above is live, not dead code.
					# Same technique: flush the frag queue, then UPDATE the most
					# recent matching row. ev_obj_b = victim player string,
					# ev_obj_c = weapon, properties carry headshot/prone/scope/ammo.
					$ev_type = 901;  # KTP frag-context marker

					if ($ktp_actor_player_id && $ktp_victim_player_id) {
							# Flush pending frags so the kill is in the DB
							flushEventTable("Frags");

							my $fc_weapon   = $ev_obj_c || "";
							# DODX reports the precise alternate-fire weapon while the
							# stock DoD log records the owning/base weapon.  Keep the
							# association exact on server, actors and producer second,
							# but accept only these documented one-way aliases.  A broad
							# weapon fallback could steal an unrelated frag after loss.
							my %fc_stock_weapon_alias = (
								"brit_knife"     => "amerknife",
								"garandbutt"     => "garand",
								"bayonet"        => "kar",
								"fcarbine"       => "m1carbine",
								"scoped_fg42"    => "fg42",
								"k43butt"        => "k43",
								"scoped_enfield" => "enfield",
								"enf_bayonet"    => "enfield",
							);
							my @fc_weapon_candidates = ($fc_weapon);
							push @fc_weapon_candidates, $fc_stock_weapon_alias{$fc_weapon}
								if exists $fc_stock_weapon_alias{$fc_weapon};
							my $fc_weapon_where = join(", ", map {
								"'".quoteSQL($_)."'"
							} @fc_weapon_candidates);
							# frag_context_recorded is the exactly-once claim guard, so it cannot also
							# vouch for what was claimed: getProperties yields "" for an empty field,
							# Perl numifies that to a measured-looking 0, and these columns are NOT NULL.
							# Bounds are the narrower of the column and the producer's own range, so a
							# bad value cannot abort the whole UPDATE under strict mode.
							# k_prone is the raw pronestate, richer than the 0/1/2 migration 005 lists.
							# BEGIN KTP FRAG CONTEXT PAYLOAD
							my @fc_context_spec = (
								["headshot",              0,  0,     1],
								["k_prone",               0, -128, 127],
								["v_prone",               0, -128, 127],
								["k_scope",               0,  0,     1],
								["v_scope",               0,  0,     1],
								["k_clip",               -1, -1, 32767],
								["k_ammo",               -1, -1, 32767],
								["v_clip",               -1, -1, 32767],
								["v_ammo",               -1, -1, 32767],
								["is_last_flag_defense",  0,  0,     1],
							);
							my (%fc_context, @fc_unusable);
							foreach my $fc_field (@fc_context_spec) {
								my ($fc_name, $fc_unknown, $fc_min, $fc_max) = @{$fc_field};
								my $fc_raw = $ev_properties_hash{$fc_name};
								if (defined($fc_raw) && $fc_raw =~ /^-?\d+\z/
									&& $fc_raw >= $fc_min && $fc_raw <= $fc_max) {
									$fc_context{$fc_name} = int($fc_raw);
								} else {
									$fc_context{$fc_name} = $fc_unknown;
									push(@fc_unusable, $fc_name."=".
										(defined($fc_raw) ? "'".$fc_raw."'" : "<absent>"));
								}
							}
							# A partial payload still carries a real headshot, which feeds the ladder, so
							# the row is written and claimed either way -- only the certification is held.
							my $fc_certified = @fc_unusable ? 0 : 1;
							if (@fc_unusable) {
								&printEvent("KTP_BAD_PROPERTY", "frag_context: context not certified for killer=".$ktp_actor_player_id." victim=".$ktp_victim_player_id.", unusable: ".join(" ", @fc_unusable), 1, 1);
							}
							# END KTP FRAG CONTEXT PAYLOAD
							my ($fc_half, $fc_map, $fc_context_source);
							my $fc_context_error = "legacy producer context absent";
							my $fc_has_explicit_context =
								ktpHasExplicitProducerContext($ev_properties_hash{"matchid"});
							if ($fc_has_explicit_context) {
								($fc_half, $fc_map, $fc_context_error, $fc_context_source) =
									ktpResolveValidatedProducerEventContext(
										$ev_properties_hash{"matchid"},
										$ev_properties_hash{"half"},
										$ev_properties_hash{"game_time"},
										$ev_properties_hash{"event_epoch"});
							}
							my $fc_clock_sql = "";
							my $fc_time_where =
								"AND eventTime >= FROM_UNIXTIME(".($ev_unixtime - 10).")";
							my $fc_match_description = "legacy receipt window";
							if ($fc_context_error eq "") {
								my $fc_event_epoch = int($ev_properties_hash{"event_epoch"});
								$fc_clock_sql = ", game_time = ".($ev_properties_hash{"game_time"} + 0).
									", event_epoch = ".int($ev_properties_hash{"event_epoch"}).
									", producer_match_id = '".quoteSQL($ev_properties_hash{"matchid"})."'".
									", producer_half = ".int($fc_half);
								$fc_time_where =
									"AND eventTime >= FROM_UNIXTIME(".$fc_event_epoch.") ".
									"AND eventTime < FROM_UNIXTIME(".($fc_event_epoch + 1).")";
								$fc_match_description = "exact producer second";
							} elsif ($fc_has_explicit_context) {
								ktpWarnProducerClock("frag_context", $fc_context_error);
							}

							# k_position/v_position are "x y z" (ksc_origin_str's format,
							# same as assist/break positions) -- present only when the
							# plugin-side origin read succeeded; Phase 5's positions
							# guard (never fabricate 0 0 0) applies here too.
							# Excluded from certification: these columns are nullable, so NULL already
							# says unknown without spending the row's certification.
							my $fc_pos_sql = "";
							if (defined($ev_properties_hash{"k_position"}) && $ev_properties_hash{"k_position"} =~ /^(-?\d+)\s+(-?\d+)\s+(-?\d+)$/) {
								$fc_pos_sql .= ", pos_x = $1, pos_y = $2, pos_z = $3";
							}
							if (defined($ev_properties_hash{"v_position"}) && $ev_properties_hash{"v_position"} =~ /^(-?\d+)\s+(-?\d+)\s+(-?\d+)$/) {
								$fc_pos_sql .= ", pos_victim_x = $1, pos_victim_y = $2, pos_victim_z = $3";
							}

							# Authoritative producer clocks use FIFO only inside the exact
							# producer second, so a lost marker cannot shift later clocks.
							# Old/sentinel emitters retain the preexisting receipt-window
							# tactical update, but those rows receive no producer clocks.
							my $fc_rv = &execNonQuery("
								UPDATE hlstats_Events_Frags
								SET headshot = ".$fc_context{'headshot'}.",
									k_prone = ".$fc_context{'k_prone'}.",
									v_prone = ".$fc_context{'v_prone'}.",
									k_scope = ".$fc_context{'k_scope'}.",
									v_scope = ".$fc_context{'v_scope'}.",
									k_clip = ".$fc_context{'k_clip'}.",
									k_ammo = ".$fc_context{'k_ammo'}.",
									v_clip = ".$fc_context{'v_clip'}.",
									v_ammo = ".$fc_context{'v_ammo'}.",
									is_last_flag_defense = ".$fc_context{'is_last_flag_defense'}.",
									frag_context_recorded = 1,
									frag_context_certified = ".$fc_certified."
									$fc_pos_sql
									$fc_clock_sql
								WHERE serverId = ".$g_servers{$s_addr}->{'id'}."
								AND killerId = ".int($ktp_actor_player_id)."
								AND victimId = ".int($ktp_victim_player_id)."
								AND weapon IN ($fc_weapon_where)
								AND frag_context_recorded = 0
								$fc_time_where
								ORDER BY id ASC
								LIMIT 1
							");
							if (defined($fc_rv) && $fc_rv == 0) {
								&printEvent("KTP_NO_ROW_MATCHED", "frag_context: no $fc_match_description frag for killer=".$ktp_actor_player_id." victim=".$ktp_victim_player_id." weapon=$fc_weapon -- likely a dropped UDP frag line", 1, 1);
							}
							if (defined($fc_rv) && $fc_rv > 0 &&
								!defined($g_ktpMatchContext{$s_addr})) {
								ktpRefreshLateHeadshots(
									$g_servers{$s_addr}->{'id'}, $ktp_actor_player_id);
							}
							$ev_status = "Frag context marked for ".$ktp_actor_identity->{"uniqueid"}." -> ".$ktp_victim_identity->{"uniqueid"}." with $fc_weapon";
					}
				} elsif ($ev_obj_a eq "damage") {
					# KTP: Per-hit damage ledger marker from ktp_stats_capture.inc,
					# fired on every client_damage hit -- enemy, team, and self
					# alike. Unlike headshot_kill/frag_context, this is not an
					# UPDATE onto an existing row (there is no independent "damage"
					# row from the stock daemon to update) -- it INSERTs directly
					# into ktp_damage_events, a standalone table, not one of the
					# generic recordEvent-batched hlstats_Events_* tables.
					# ev_obj_b = victim player string, ev_obj_c = weapon.
					$ev_type = 605;  # KTP damage-ledger marker

					if ($ktp_actor_player_id && $ktp_victim_player_id) {
							$ev_status = &doEvent_KTPDamage(
								$ktp_actor_player_id, $ktp_victim_player_id,
								$ev_obj_c || "",
								$ev_properties_hash{"damage"} // 0,
								$ev_properties_hash{"damage_capped"} // 0,
								$ev_properties_hash{"hitplace"} // 0,
								$ev_properties_hash{"game_time"} // 0,
								$ev_properties_hash{"event_epoch"},
								$ev_properties_hash{"matchid"},
								$ev_properties_hash{"half"}
							);
					}
				} else {

				my ($playerinfo, $victiminfo);
				if ($ev_obj_a eq "assist") {
					# Reuse the pure parse and durable ids. The adapter selects an
					# exact currently-live tuple without altering reconnect state.
					$playerinfo = &ktpIdentityForGenericAction(
						$ktp_actor_identity, $ktp_actor_player_id);
					$victiminfo = &ktpIdentityForGenericAction(
						$ktp_victim_identity, $ktp_victim_player_id);
				} else {
					$playerinfo = &getPlayerInfo($ev_player, 1);
					$victiminfo = &getPlayerInfo($ev_obj_b, 1);
				}
				$ev_type = 10;

				if ($playerinfo) {
					if ($victiminfo) {
						$ev_status = &doEvent_PlayerPlayerAction(
							$playerinfo->{"userid"},
							$playerinfo->{"uniqueid"},
							$victiminfo->{"userid"},
							$victiminfo->{"uniqueid"},
							$ev_obj_a,
							undef,
							undef,
							undef,
							undef,
							undef,
							undef,
							&getProperties($ev_properties)
						);
					}

					$ev_type = 11;

					$ev_status = &doEvent_PlayerAction(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_obj_a,
						undef,
						undef,
						undef,
						&getProperties($ev_properties)
					);
				}
				} # end else (not headshot_kill)
			} else {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				$ev_type = 11;
				
				if ($playerinfo) {
					$ev_status = &doEvent_PlayerAction(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_obj_a,
						undef,
						undef,
						undef,
				        &getProperties($ev_properties)
					);
				}
			}
		} elsif ($s_output =~ /^(?:\[STATSME\] )?"(.+?(?:<.+?>)*)" triggered "(weaponstats\d{0,1})"(.*)$/ ) {
			# Prototype: [STATSME] "player" triggered "weaponstats?"[properties]
			# Matches:
			# 501. Statsme weaponstats
			# 502. Statsme weaponstats2
	
			$ev_player = $1;
			$ev_verb   = $2; # weaponstats; weaponstats2
			$ev_properties = $3;
			%ev_properties = &getProperties($ev_properties);
	
			if (like($ev_verb, "weaponstats")) {
				$ev_type = 501;
				my $playerinfo = &getPlayerInfo($ev_player, 0);
				
				if ($playerinfo) {
					my $playerId = $playerinfo->{"userid"};
					my $playerUniqueId = $playerinfo->{"uniqueid"};
					my $ingame = 0;
					
					$ingame = 1 if (lookupPlayer($s_addr, $playerId, $playerUniqueId));
					
					if (!$ingame) {
						&getPlayerInfo($ev_player, 1);
					}
					
					$ev_status = &doEvent_Statsme(
						$playerId,
						$playerUniqueId,
						$ev_properties{"weapon"},
						$ev_properties{"shots"},
						$ev_properties{"hits"},
						$ev_properties{"headshots"},
						$ev_properties{"damage"},
						$ev_properties{"kills"},
						$ev_properties{"deaths"}
					);

					# KTP: Accumulate score for match stats (score comes from weaponstats)
					if (defined($g_ktpMatchContext{$s_addr}) &&
						$g_ktpMatchContext{$s_addr}{match_id} ne "") {
						my $score_val = $ev_properties{"score"} || 0;
						if ($score_val > 0) {
							my $mid = $g_ktpMatchContext{$s_addr}{match_id};
							my $hnum = $g_ktpMatchContext{$s_addr}{half_num} || 0;
							my $player = lookupPlayer($s_addr, $playerId, $playerUniqueId);
							if ($player) {
								$g_ktpScoreAccum{$mid}{$player->{playerid}}{$hnum} += $score_val;
							}
						}
					}

					if (!$ingame) {
						&doEvent_Disconnect(
							$playerId,
							$playerUniqueId,
							""
						);
					}
				}
			} elsif (like($ev_verb, "weaponstats2")) {
				$ev_type = 502;
				my $playerinfo = &getPlayerInfo($ev_player, 0);
				
				if ($playerinfo) {
					my $playerId = $playerinfo->{"userid"};
					my $playerUniqueId = $playerinfo->{"uniqueid"};
					my $ingame = 0;
					
					$ingame = 1 if (lookupPlayer($s_addr, $playerId, $playerUniqueId));
					
					if (!$ingame) {
						&getPlayerInfo($ev_player, 1);
					}
					
					$ev_status = &doEvent_Statsme2(
						$playerId,
						$playerUniqueId,
						$ev_properties{"weapon"},
						$ev_properties{"head"},
						$ev_properties{"chest"},
						$ev_properties{"stomach"},
						$ev_properties{"leftarm"},
						$ev_properties{"rightarm"},
						$ev_properties{"leftleg"},
						$ev_properties{"rightleg"}
					);
					
					if (!$ingame) {
						&doEvent_Disconnect(
							$playerId,
							$playerUniqueId,
							""
						);
					}
				}
			}
		} elsif ($s_output =~ /^(?:\[STATSME\] )?"(.+?(?:<.+?>)*)" triggered "(latency|time)"(.*)$/ ) {
			# Prototype: [STATSME] "player" triggered "latency|time"[properties]
			# Matches:
			# 503. Statsme latency
			# 504. Statsme time
	
			$ev_player = $1;
			$ev_verb   = $2; # latency; time
			$ev_properties = $3;
			%ev_properties = &getProperties($ev_properties);
	
			if ($ev_verb eq "time") {
				$ev_type = 504;
				my $playerinfo = &getPlayerInfo($ev_player, 0);
	
				if ($playerinfo) {
					my ($min, $sec) = split(/:/, $ev_properties{"time"});
					my $hour = sprintf("%d", $min / 60);
	
					if ($hour) {
						$min = $min % 60;
					}
	
					$ev_status = &doEvent_Statsme_Time(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						"$hour:$min:$sec"
					);
				}
			} else { # latency
				$ev_type = 503;
				my $playerinfo = &getPlayerInfo($ev_player, 0);
	
				if ($playerinfo) {
					$ev_status = &doEvent_Statsme_Latency(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_properties{"ping"}
					);
				}
			}
		} elsif ($s_output =~ /^"(.+?(?:<.+?>)*?)" triggered "clantag" \(value "(.+?)?"\)$/) {
			# L 08/14/2014 - 18:04:21: "Laam4<7><STEAM_1:0:106564><Unassigned>" triggered "clantag" (value "Kunіngas")
			$ev_player = $1;
			$ev_clantag = $2;
			
			if ($ev_clantag) {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				$ev_type = 600;
				
				if ($playerinfo) {
					$ev_status = &doEvent_Clan(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_clantag
					);
				}
			}
		} elsif ($s_output =~ /^"(.+?(?:<.+?>)*?)" api_request "playerinfo" \(value "(.+?)?"\)$/) {

			$ev_player = $1;
			$ev_queryId = $2;
			
			if ($ev_queryId) {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				if ($playerinfo) {
					$ev_type = 101;
					$ev_status = &doEvent_ApiReqestPlayerInfo($playerinfo->{"userid"}, $playerinfo->{"uniqueid"}, $ev_queryId);
				}
			}
		} elsif ($s_output =~ /^"(.+?(?:<.+?>)*?)"(?:\s\[(-?\d+)\s(-?\d+)\s(-?\d+)\]) ([a-zA-Z,_\s]+) "(.+?)"(.*)$/) {
			# 4. Suicide for CS:GO
			$ev_player = $1;
			$ev_Xcoord = $2;
			$ev_Ycoord = $3;
			$ev_Zcoord = $4;
			$ev_verb   = $5;
			$ev_obj_a  = $6;
			
			if ($ev_verb eq "committed suicide with") {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				$ev_type = 4;
				
				if ($playerinfo) {
					$ev_status = &doEvent_Suicide(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_obj_a,
						$ev_Xcoord,
						$ev_Ycoord,
						$ev_Zcoord
					);
				}
			}
		} elsif ($s_output =~ /^"(.+?(?:<.+?>)*?)" ([a-zA-Z,_\s]+) "(.+?)"(.*)$/) {
			# Prototype: "player" verb "obj_a"[properties]
			# Matches:
			#  1. Connection
			#  4. Suicides (Fixed above for CSGO)
			#  5. Team Selection
			#  6. Role Selection
			#  7. Change Name
			# 11. Player Objectives/Actions
			# 14. a) Chat; b) Team Chat
			
			$ev_player = $1;
			$ev_verb   = $2;
			$ev_obj_a  = $3;
			$ev_properties = $4;
			%ev_properties = &getProperties($ev_properties);
			
			if ($ev_verb eq "connected, address") {
				my $ipAddr = $ev_obj_a;
				my $playerinfo;
				
				if ($ipAddr =~ /([\d\.]+):(\d+)/) {
					$ipAddr = $1;
				}
				
				$playerinfo = &getPlayerInfo($ev_player, 1, $ipAddr);
				
				$ev_type = 1;
				
				if ($playerinfo) {
					if (($playerinfo->{"uniqueid"} =~ /UNKNOWN/) || ($playerinfo->{"uniqueid"} =~ /PENDING/) || ($playerinfo->{"uniqueid"} =~ /VALVE_ID_LAN/)) {
						$ev_status = "(DELAYING CONNECTION): $s_output";
	
	                    if ($g_mode ne "LAN")  {
							my $p_name   = $playerinfo->{"name"};
							my $p_userid = $playerinfo->{"userid"};
							&printEvent("SERVER", "LATE CONNECT [$p_name/$p_userid] - STEAM_ID_PENDING");
							$g_preconnect->{"$s_addr/$p_userid/$p_name"} = {
								ipaddress => $ipAddr,
								name => $p_name,
								server => $s_addr,
								timestamp => $ev_daemontime
							};
						}   
					} else {
						$ev_status = &doEvent_Connect(
							$playerinfo->{"userid"},
							$playerinfo->{"uniqueid"},
							$ipAddr
						);
					}
				}
			} elsif ($ev_verb eq "committed suicide with") {
				# GoldSrc suicides reach the daemon through this branch, not the
				# bracketed-coordinate one above: that branch requires a "[x y z]"
				# block DoD never emits, so doEvent_Suicide was unreachable for
				# this game and hlstats_Events_Suicides stayed empty fleet-wide
				# even though the handler, schema and aggregation were all correct.
				# No coordinates in this log format, hence undef (same as the
				# other coordinate-less branches here).
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				$ev_type = 4;
				
				if ($playerinfo) {
					$ev_status = &doEvent_Suicide(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_obj_a,
						undef,
						undef,
						undef
					);
				}
			} elsif ($ev_verb eq "joined team") {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				$ev_type = 5;
				
				if ($playerinfo) {
					$ev_status = &doEvent_TeamSelection(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_obj_a
					);
				}
			} elsif ($ev_verb eq "changed role to") {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				$ev_type = 6;
				
				if ($playerinfo) {
					$ev_status = &doEvent_RoleSelection(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_obj_a
					);
				}
			} elsif ($ev_verb eq "changed name to") {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				$ev_type = 7;
				
				if ($playerinfo) {
					$ev_status = &doEvent_ChangeName(
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_obj_a
					);
				}
			} elsif ($ev_verb eq "triggered") {

			    # in cs:s players dropp the bomb if they are the only ts
			    # and disconnect...the dropp the bomb after they disconnected :/
				my $ktp_buffered_player_id = 0;
			    if ($ev_obj_a =~ /^(?:life_boundary|cap_break|break_context|position_sample)$/) {
				  # BEGIN KTP BUFFERED STANDALONE IDENTITY
				  # Every KSC-buffered standalone marker can arrive after a reconnect.
				  # Parse once and resolve durably without getPlayerInfo(). cap_break
				  # still uses the stock rating-neutral generic action handler, with a
				  # copied exact-live tuple selected by durable id.
				  my $ktp_buffered_identity = &ktpParsePlayerIdentity($ev_player);
				  $ktp_buffered_player_id = &ktpResolvePlayerIdentity($ktp_buffered_identity);
				  $playerinfo = ($ev_obj_a eq "cap_break")
					? &ktpIdentityForGenericAction($ktp_buffered_identity, $ktp_buffered_player_id)
					: $ktp_buffered_identity;
				  # END KTP BUFFERED STANDALONE IDENTITY
			    } elsif ($ev_obj_a eq "Dropped_The_Bomb") {
				  $playerinfo = &getPlayerInfo($ev_player, 0);
			    } else {
				  $playerinfo = &getPlayerInfo($ev_player, 1);
				}
				# KTP life markers are their own durable event type even when the
				# player cannot be resolved. That leaves an explicit BAD DATA/drop
				# diagnostic instead of silently falling through as a stock action.
				$ev_type = 611 if ($ev_obj_a eq "life_boundary");
				if ($playerinfo) {
					if ($ev_obj_a eq "life_boundary") {
						# KTP: low-volume, durable life start/end marker from
						# ktp_stats_capture.inc. The marker carries an explicit match id
						# because daemon memory is intentionally not the sole source of
						# attribution after a daemon restart. doEvent_KTPLifeBoundary
						# validates the complete payload and proves the half context.
						my $lifePlayerId = $ktp_buffered_player_id;

						if ($lifePlayerId) {
							$ev_status = &doEvent_KTPLifeBoundary(
								$lifePlayerId,
								$playerinfo->{"userid"},
								$ev_properties{"matchid"},
								$ev_properties{"half"},
								$ev_properties{"kind"},
								$ev_properties{"reason"},
								$ev_properties{"team"},
								$ev_properties{"class"},
								$ev_properties{"slot"},
								$ev_properties{"round_live"},
								$ev_properties{"game_time"},
								$ev_properties{"event_epoch"}
							);
						} else {
							$ev_status = "Life boundary dropped: unresolved player " .
								$playerinfo->{"uniqueid"};
						}
					} elsif ($ev_obj_a eq "break_context") {
						# KTP: follow-up marker on cap_break from
						# ktp_stats_capture.inc, same technique frag_context uses
						# on Frags but UPDATEing the most recent matching
						# hlstats_Events_PlayerActions row instead (matched by
						# playerId + the cap_break actionId, looked up from the
						# in-memory actions table rather than a DB round-trip).
						$ev_type = 606;  # KTP break-context marker

						my $capBreakActionId = $g_games{$g_servers{$s_addr}->{game}}{actions}{"cap_break"}{id};

						if ($ktp_buffered_player_id && $capBreakActionId) {
							flushEventTable("PlayerActions");

							# Anything not matching the producer's own format is unknown, not zero.
							# A blank or malformed value must NOT numify to 0 -- that is the false
							# default that hid k_prone for nine seasons, and getProperties yields ""
							# rather than undef for an empty field. Bounds keep a bad value from
							# overflowing the column and aborting the whole UPDATE under strict mode.
							my $bc_raw_contesters = $ev_properties{"contester_count"};
							my $bc_raw_remaining  = $ev_properties{"time_remaining"};
							my $bc_raw_capout     = $ev_properties{"is_capout"};
							my $bc_contesters = (defined($bc_raw_contesters)
								&& $bc_raw_contesters =~ /^\d+$/ && $bc_raw_contesters <= 32767)
								? int($bc_raw_contesters) : "NULL";
							my $bc_remaining  = (defined($bc_raw_remaining)
								&& $bc_raw_remaining =~ /^\d+(?:\.\d+)?$/ && $bc_raw_remaining < 100000)
								? ($bc_raw_remaining + 0) : "NULL";
							my $bc_capout     = (defined($bc_raw_capout) && $bc_raw_capout =~ /^[01]$/)
								? ($bc_raw_capout + 0) : "NULL";

							# A present-but-unparseable value is a producer/transport fault. Silence
							# here would store it as NULL and look identical to an absent marker.
							my @bc_bad = ();
							push(@bc_bad, "contester_count=".$bc_raw_contesters)
								if (defined($bc_raw_contesters) && $bc_contesters eq "NULL");
							push(@bc_bad, "time_remaining=".$bc_raw_remaining)
								if (defined($bc_raw_remaining) && $bc_remaining eq "NULL");
							push(@bc_bad, "is_capout=".$bc_raw_capout)
								if (defined($bc_raw_capout) && $bc_capout eq "NULL");
							if (@bc_bad) {
								&printEvent("KTP_BAD_PROPERTY", "break_context: unparseable, stored as unknown for player=".$ktp_buffered_player_id.": ".join(" ", @bc_bad), 1, 1);
							}

							# Time-bounded for the same reason as frag_context's UPDATE
							# above, but the window alone is not enough: a dropped cap_break
							# line whose context still arrives would silently rewrite the
							# player's PREVIOUS break with this break's numbers. The claim
							# column makes that a logged no-op instead. DESC, not frag's ASC:
							# frag narrows to the exact producer second, this has only the 60s
							# receipt window, so the newest unclaimed break is the better pair.
							my $bc_rv = &execNonQuery("
								UPDATE hlstats_Events_PlayerActions
								SET contester_count = ".$bc_contesters.",
									time_remaining = ".$bc_remaining.",
									is_capout = ".$bc_capout.",
									break_context_recorded = 1
								WHERE serverId = ".$g_servers{$s_addr}->{'id'}."
								AND playerId = ".int($ktp_buffered_player_id)."
								AND actionId = ".int($capBreakActionId)."
								AND break_context_recorded = 0
								AND eventTime >= FROM_UNIXTIME(".($ev_unixtime - 60).")
								ORDER BY id DESC
								LIMIT 1
							");
							if (defined($bc_rv) && $bc_rv == 0) {
								&printEvent("KTP_NO_ROW_MATCHED", "break_context: no unclaimed cap_break within 60s for player=".$ktp_buffered_player_id." -- likely a dropped UDP cap_break line", 1, 1);
							}
							$ev_status = "Break context marked for ".$playerinfo->{"uniqueid"}.": contesters=$bc_contesters remaining=$bc_remaining capout=$bc_capout";
						}
					} elsif ($ev_obj_a eq "position_sample") {
						# KTP: periodic roster-position sample from
						# ktp_stats_capture.inc's ksc_position_broadcast_task
						# (KSC_POSITION_BROADCAST_SECS, currently 30s). Raw facts
						# only -- no "is this holding forward territory" judgment
						# happens here, that's entirely query-layer, reading this
						# table plus ktp_flag_positions. Standalone table, direct
						# INSERT, same shape as doEvent_KTPDamage -- not routed
						# through recordEvent's generic hlstats_Events_* batching.
						$ev_type = 608;  # KTP position-sample marker

						if ($ktp_buffered_player_id) {
							$ev_status = &doEvent_KTPPosition(
								$ktp_buffered_player_id,
								$ev_properties{"team"} // 0,
								$ev_properties{"position"} // "",
								$ev_properties{"game_time"} // 0
							);
						}
					} elsif ($ev_obj_a eq "player_changeclass" && defined($ev_properties{newclass})) {

						$ev_type = 6;

						$ev_status = &doEvent_RoleSelection(
							$playerinfo->{"userid"},
							$playerinfo->{"uniqueid"},
							$ev_properties{newclass}
						);
					} else {
						if ($g_servers{$s_addr}->{play_game} == TFC())
						{
							if ($ev_obj_a eq "Sentry_Destroyed")
							{
								$ev_obj_a = "Sentry_Dismantle";
							}
							elsif ($ev_obj_a eq "Dispenser_Destroyed")
							{
								$ev_obj_a = "Dispenser_Dismantle";
							}
							elsif ($ev_obj_a eq "Teleporter_Entrance_Destroyed")
							{
								$ev_obj_a = "Teleporter_Entrance_Dismantle"
							}
							elsif ($ev_obj_a eq "Teleporter_Exit_Destroyed")
							{
								$ev_obj_a = "Teleporter_Exit_Dismantle"
							}
						}
						
						$ev_type = 11;
				
						$ev_status = &doEvent_PlayerAction(
							$playerinfo->{"userid"},
							$playerinfo->{"uniqueid"},
							$ev_obj_a,
							undef,
							undef,
							undef,
							%ev_properties
						);
					}
				}
			} elsif ($ev_verb eq "triggered a") {
				my $playerinfo = &getPlayerInfo($ev_player, 1);

				if ($playerinfo && $ev_obj_a eq "dod_capture_area") {
					# KTP: DoD 1.3 (GoldSrc) flag-capture completion --
					#     "Player<uid><steamid><Team>" triggered a "dod_capture_area" - "POINT_NAME"
					# One line per capping player (DoD 1.3's multi-capper mechanic:
					# some points need two players standing on them simultaneously,
					# some need one), plus a redundant "Team X triggered a
					# dod_capture_area - POINT_NAME" line carrying no information
					# the per-player rows don't already have (team is on every
					# player row) -- that one hits the generic Team "..." branch
					# above, isn't seeded in hlstats_Actions, and is left
					# discarded on purpose rather than double-recorded here.
					#
					# The trailing "- \"POINT_NAME\"" is a bare dash-suffixed
					# string, not the parenthesized (key "val") shape
					# getProperties() expects -- that function's own DoD-specific
					# $dods_flag/flagindex handling is for DoD:Source's different
					# log format and never matches these GoldSrc 1.3 lines, so
					# the point name is parsed directly here instead.
					$ev_type = 609;  # KTP flag-capture marker

					my ($flagname) = ($ev_properties =~ /-\s*"(.+?)"\s*$/);

					my $capperId = lookupPlayer($s_addr, $playerinfo->{"userid"}, $playerinfo->{"uniqueid"});

					if ($capperId) {
						$ev_status = &doEvent_KTPFlagCapture(
							$capperId->{playerid},
							$playerinfo->{"team"},
							$flagname // ""
						);
					}
				} else {
					$ev_type = 11;

					if ($playerinfo)
					{
						$ev_status = &doEvent_PlayerAction(
							$playerinfo->{"userid"},
							$playerinfo->{"uniqueid"},
							$ev_obj_a,
							undef,
							undef,
							undef,
							%ev_properties
						);
					}
				}
			} elsif ($ev_verb eq "say" || $ev_verb eq "say_team" || $ev_verb eq "say_squad") {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				$ev_type = 14;
				
				if ($playerinfo) {
					$ev_status = &doEvent_Chat(
						$ev_verb,
						$playerinfo->{"userid"},
						$playerinfo->{"uniqueid"},
						$ev_obj_a
					);
				}
			}
		} elsif ($s_output =~ /^(?:Kick: )?"(.+?(?:<.+?>)*)" ([^\(]+)(.*)$/) {
			# Prototype: "player" verb[properties]
			# Matches:
			#	 1. Connection (CS:GO only)
			#  2. Enter Game
			#  3. Disconnection
			
			$ev_player = $1;
			$ev_verb   = $2;
			$ev_properties = $3;
			%ev_properties = &getProperties($ev_properties);
			
			if (like($ev_verb, "entered the game")) {
				my $playerinfo = &getPlayerInfo($ev_player, 1);
				
				if ($playerinfo) {
					$ev_type = 2;
					$ev_status = &doEvent_EnterGame($playerinfo->{"userid"}, $playerinfo->{"uniqueid"}, $ev_obj_a);
				}
			} elsif (like($ev_verb, "disconnected") || like($ev_verb, "was kicked")) {
				my $playerinfo = &getPlayerInfo($ev_player, 0);
				
				if ($playerinfo) {
					$ev_type = 3;
	
					$userid   = $playerinfo->{userid};
					$uniqueid = $playerinfo->{uniqueid};
	
					$ev_status = &doEvent_Disconnect(
						$playerinfo->{userid},
						$playerinfo->{uniqueid},
						$ev_properties
					);
				}
			}
			elsif (like($ev_verb, "STEAM USERID validated") || like($ev_verb, "VALVE USERID validated")) {               
				
				my $isCSGO = ($g_servers{$s_addr}->{play_game} == CSGO());
				my $playerinfo = &getPlayerInfo($ev_player, $isCSGO ? 1 : 0);
	
				if ($playerinfo) {                       
					
					$ev_type = 1;
					
					if ($isCSGO) {
						$ev_status = &doEvent_Connect($playerinfo->{userid}, $playerinfo->{uniqueid}, $playerinfo->{address});
					}	
				}
			}
		} elsif ($s_output =~ /^Team "(.+?)" ([^"\(]+) "([^"]+)"(.*)$/) {
			# Prototype: Team "team" verb "obj_a"[properties]
			# Matches:
			# 12. Team Objectives/Actions
			# 1200. Team Objective With Players involved
			# 15. Team Alliances
			
			$ev_team   = $1;
			$ev_verb   = $2;
			$ev_obj_a  = $3;
			$ev_properties = $4;
			%ev_properties_hash = &getProperties($ev_properties);
			
			if ($ev_obj_a eq "pointcaptured") {
				$numcappers = $ev_properties_hash{numcappers};
				if ($g_debug > 1) {
					print "NumCappers = ".$numcappers."\n";
				}
				foreach ($i = 1; $i <= $numcappers; $i++) {
					# reward each player involved in capturing
					$player = $ev_properties_hash{"player".$i};
					if ($g_debug > 1) {
						print $i." -> ".$player."\n";
					}
					#$position = $ev_properties_hash{"position".$i};
					my $playerinfo = &getPlayerInfo($player, 1);
					if ($playerinfo) {
						$ev_status = &doEvent_PlayerAction(
							$playerinfo->{"userid"},
							$playerinfo->{"uniqueid"},
							$ev_obj_a,
							"",
							"",
							"",
							&getProperties($ev_properties)
						);
					}
				}
			}
 			if ($ev_obj_a eq "captured_loc") {
			#	$flag_name = $ev_properties_hash{flagname};
				$player_a  = $ev_properties_hash{player_a};
				$player_b  = $ev_properties_hash{player_b};
  			  
				my $playerinfo_a = &getPlayerInfo($player_a, 1);
				if ($playerinfo_a) {
					$ev_status = &doEvent_PlayerAction(
						$playerinfo_a->{"userid"},
						$playerinfo_a->{"uniqueid"},
						$ev_obj_a,
						"",
						"",
						"",
						&getProperties($ev_properties)
					);
				}

				my $playerinfo_b = &getPlayerInfo($player_b, 1);
				if ($playerinfo_b) {
					$ev_status = &doEvent_PlayerAction(
						$playerinfo_b->{"userid"},
						$playerinfo_b->{"uniqueid"},
						$ev_obj_a,
						"",
						"",
						"",
						&getProperties($ev_properties)
					);
				}
			}  
			
			if (like($ev_verb, "triggered")) {
				if ($ev_obj_a ne "captured_loc") {
					$ev_type = 12;
					$ev_status = &doEvent_TeamAction(
						$ev_team,
						$ev_obj_a,
						&getProperties($ev_properties)
					);
				}
			} elsif (like($ev_verb, "triggered a")) {
				$ev_type = 12;
				$ev_status = &doEvent_TeamAction(
					$ev_team,
					$ev_obj_a
				);
			}
		} elsif ($s_output =~ /^(Rcon|Bad Rcon): "rcon [^"]+"([^"]+)"\s+(.+)" from "([0-9\.]+?):(\d+?)"(.*)$/) {
			# Prototype: verb: "rcon ?..."obj_a" obj_b" from "obj_c"[properties]
			# Matches:
		    # 20. HL1 a) Rcon; b) Bad Rcon
			
			$ev_verb   = $1;
			$ev_obj_a  = $2; # password
			$ev_obj_b  = $3; # command
			$ev_obj_c  = $4; # ip
			$ev_obj_d  = $5; # port
			$ev_properties = $6;
			%ev_properties = &getProperties($ev_properties);
			if ($g_rcon_ignoreself == 0 || $ev_obj_c ne $s_ip) {
				$ev_obj_b = substr($ev_obj_b, 0, 255);
				if (like($ev_verb, "Rcon")) {
					$ev_type = 20;
					$ev_status = &doEvent_Rcon(
						"OK",
						$ev_obj_b,
						"",
						$ev_obj_c
					);
				} elsif (like($ev_verb, "Bad Rcon")) {
					$ev_type = 20;
					$ev_status = &doEvent_Rcon(
						"BAD",
						$ev_obj_b,
						$ev_obj_a,
						$ev_obj_c
					);
				}
			} else {
				$ev_status = "(IGNORED) Rcon from \"$ev_obj_a:$ev_obj_b\": \"$ev_obj_c\"";
			}
		} elsif ($s_output =~ /^rcon from "(.+?):(.+?)": (?:command "(.*)".*|(Bad) Password)$/) {
			# Prototype: verb: "rcon ?..."obj_a" obj_b" from "obj_c"[properties]
			# Matches:
		    # 20. a) Rcon;
			
			$ev_obj_a  = $1; # ip
			$ev_obj_b  = $2; # port
			$ev_obj_c  = $3; # command
			$ev_isbad  = $4; # if bad, "Bad"
			if ($g_rcon_ignoreself == 0 || $ev_obj_a ne $s_ip) {
				if ($ev_isbad ne "Bad") {
					$ev_type = 20;
					@cmds = split(/;/,$ev_obj_c);
					foreach(@cmds)
					{
						$ev_status = &doEvent_Rcon(
							"OK",
							substr($_, 0, 255),
							"",
							$ev_obj_a
						);
					}
				} else {
					$ev_type = 20;
					$ev_status = &doEvent_Rcon(
						"BAD",
						"",
						"",
						$ev_obj_a
					);
				}
			} else {
				$ev_status = "(IGNORED) Rcon from \"$ev_obj_a:$ev_obj_b\": \"$ev_obj_c\"";
			}
		} elsif ($s_output =~ /^\[(.+)\.(smx|amxx)\]\s*(.+)$/i) {
			# Prototype: Cmd:[SM] obj_a
			# Matches:
		    # Admin Mod messages

			my $ev_plugin = $1;
			my $ev_adminmod = $2;
			$ev_obj_a  = $3;

			# KTP: Check for KTP_MATCH events from KTPMatchHandler plugin
			if ($ev_obj_a =~ /^KTP_MATCH_START\s+(.*)$/) {
				# KTP: Match start event
				# Prototype: KTP_MATCH_START (matchid "xxx") (map "xxx") (half "xxx") (type "0")
				$ev_properties = $1;
				%ev_properties = &getProperties($ev_properties);
				$ev_type = 600;  # KTP event type
				$ev_status = &doEvent_KTPMatchStart(
					$ev_properties{"matchid"},
					$ev_properties{"map"},
					$ev_properties{"half"},
					$ev_properties{"type"}
				);
			} elsif ($ev_obj_a =~ /^KTP_MATCH_END\s+(.*)$/) {
				# KTP: Match end event
				# Prototype: KTP_MATCH_END (matchid "xxx") (map "xxx")
				$ev_properties = $1;
				%ev_properties = &getProperties($ev_properties);
				$ev_type = 601;  # KTP event type
				$ev_status = &doEvent_KTPMatchEnd(
					$ev_properties{"matchid"},
					$ev_properties{"map"}
				);
			} elsif ($ev_obj_a =~ /^KTP_HALF_END\s+(.*)$/) {
				# KTP: Half end event
				# Prototype: KTP_HALF_END (matchid "xxx") (map "xxx") (half "1st")
				$ev_properties = $1;
				%ev_properties = &getProperties($ev_properties);
				$ev_type = 602;  # KTP event type
				$ev_status = &doEvent_KTPHalfEnd(
					$ev_properties{"matchid"},
					$ev_properties{"map"},
					$ev_properties{"half"}
				);
			} else {
				# Default: Treat as admin message
				$ev_type = 500;
				$ev_status = &doEvent_Admin(
					(($ev_adminmod eq "smx")?"Sourcemod":"AMXX")." ($ev_plugin)",
					substr($ev_obj_a, 0, 255)
				);
			}
		} elsif ($s_output =~ /^([^"\(]+) "([^"]+)"(.*)$/) {
			# Prototype: verb "obj_a"[properties]
			# Matches:
			# 13. World Objectives/Actions
			# 19. a) Loading map; b) Started map
			# 21. Server Name
			
			$ev_verb   = $1;
			$ev_obj_a  = $2;
			$ev_properties = $3;
			%ev_properties = &getProperties($ev_properties);
			
			if (like($ev_verb, "World triggered")) {
				$ev_type = 13;
				if ($ev_obj_a eq "killlocation") {
					$ev_status = &doEvent_Kill_Loc(
						%ev_properties
					);
				} else {
					$ev_status = &doEvent_WorldAction(
						$ev_obj_a
					);
					if ($ev_obj_a eq "Round_Win" || $ev_obj_a eq "Mini_Round_Win") {
						$ev_team = $ev_properties{"winner"};
						$ev_status = &doEvent_TeamAction(
						$ev_team,
						$ev_obj_a
						);
					}
				}
			} elsif (like($ev_verb, "Loading map")) {
				$ev_type = 19;
				$ev_status = &doEvent_ChangeMap(
					"loading",
					$ev_obj_a
				);
			} elsif (like($ev_verb, "Started map")) {
				$ev_type = 19;
				$ev_status = &doEvent_ChangeMap(
					"started",
					$ev_obj_a
				);
			}
		} elsif ($s_output =~ /^KTP_MATCH_START\s+(.*)$/) {
			# KTP: Match start event from KTPMatchHandler
			# Prototype: KTP_MATCH_START (matchid "xxx") (map "xxx") (half "xxx") (type "0")
			$ev_properties = $1;
			%ev_properties = &getProperties($ev_properties);
			$ev_type = 600;  # KTP event type
			# KTP DEBUG: Log parsed properties
			&printEvent("KTP_DEBUG", "KTP_MATCH_START parsed: matchid='$ev_properties{\"matchid\"}' map='$ev_properties{\"map\"}' half='$ev_properties{\"half\"}' type='$ev_properties{\"type\"}'", 1);
			$ev_status = &doEvent_KTPMatchStart(
				$ev_properties{"matchid"},
				$ev_properties{"map"},
				$ev_properties{"half"},
				$ev_properties{"type"}
			);
		} elsif ($s_output =~ /^KTP_MATCH_END\s+(.*)$/) {
			# KTP: Match end event from KTPMatchHandler
			# Prototype: KTP_MATCH_END (matchid "xxx") (map "xxx")
			$ev_properties = $1;
			%ev_properties = &getProperties($ev_properties);
			$ev_type = 601;  # KTP event type
			# KTP DEBUG: Log parsed properties
			&printEvent("KTP_DEBUG", "KTP_MATCH_END parsed: matchid='$ev_properties{\"matchid\"}' map='$ev_properties{\"map\"}'", 1);
			$ev_status = &doEvent_KTPMatchEnd(
				$ev_properties{"matchid"},
				$ev_properties{"map"}
			);
		} elsif ($s_output =~ /^KTP_HALF_END\s+(.*)$/) {
			# KTP: Half end event from KTPMatchHandler (v0.10.69+)
			# Fires at actual gameplay end (scoreboard), BEFORE map change/warmup
			# Prototype: KTP_HALF_END (matchid "xxx") (map "xxx") (half "1st")
			$ev_properties = $1;
			%ev_properties = &getProperties($ev_properties);
			$ev_type = 602;  # KTP event type
			&printEvent("KTP_DEBUG", "KTP_HALF_END parsed: matchid='$ev_properties{\"matchid\"}' map='$ev_properties{\"map\"}' half='$ev_properties{\"half\"}'", 1);
			$ev_status = &doEvent_KTPHalfEnd(
				$ev_properties{"matchid"},
				$ev_properties{"map"},
				$ev_properties{"half"}
			);
		} elsif ($s_output =~ /^KTP_ROUND_FREEZE\s+(.*)$/) {
			# KTP: Round freeze event - pause match_id tagging
			$ev_properties = $1;
			%ev_properties = &getProperties($ev_properties);
			$ev_type = 603;  # KTP event type
			if (defined($g_ktpMatchContext{$s_addr})) {
				$g_ktpMatchContext{$s_addr}{round_live} = 0;
				&printEvent("KTP_DEBUG", "KTP_ROUND_FREEZE: match=$g_ktpMatchContext{$s_addr}{match_id}", 1);
			}
		} elsif ($s_output =~ /^KTP_ROUND_LIVE\s+(.*)$/) {
			# KTP: Round live event - resume match_id tagging
			$ev_properties = $1;
			%ev_properties = &getProperties($ev_properties);
			$ev_type = 604;  # KTP event type
			if (defined($g_ktpMatchContext{$s_addr})) {
				$g_ktpMatchContext{$s_addr}{round_live} = 1;
				&printEvent("KTP_DEBUG", "KTP_ROUND_LIVE: match=$g_ktpMatchContext{$s_addr}{match_id}", 1);
			}
		} elsif ($s_output =~ /^KTP_FLAG_POSITION\s+(.*)$/) {
			# KTP: static per-flag position from ktp_stats_capture.inc,
			# fired once per map load (controlpoints_init) -- a bare marker,
			# no player string, same shape as KTP_MATCH_START.
			# Prototype: KTP_FLAG_POSITION (map "xxx") (flag_index "0")
			#   (flag_name "xxx") (x "1234") (y "-567")
			$ev_properties = $1;
			%ev_properties = &getProperties($ev_properties);
			$ev_type = 607;  # KTP event type
			$ev_status = &doEvent_KTPFlagPosition(
				$ev_properties{"map"},
				$ev_properties{"flag_index"},
				$ev_properties{"flag_name"},
				$ev_properties{"x"},
				$ev_properties{"y"}
			);
		} elsif ($s_output =~ /^KTP_FLAG_STATE\s+(.*)$/) {
			# KTP: compact objective-ownership timeline. The plugin emits one
			# baseline per flag when match context becomes available, then only
			# owner changes. Positions are joined to the resulting intervals by
			# the analytics layer; no per-player data is present in this marker.
			$ev_properties = $1;
			%ev_properties = &getProperties($ev_properties);
			$ev_type = 610;  # KTP flag-state marker
			$ev_status = &doEvent_KTPFlagState(
				$ev_properties{"map"},
				$ev_properties{"flag_index"},
				$ev_properties{"flag_name"},
				$ev_properties{"owner"},
				$ev_properties{"initial"},
				$ev_properties{"game_time"}
			);
		} elsif ($s_output =~ /^\[MANI_ADMIN_PLUGIN\]\s*(.+)$/) {
			# Prototype: [MANI_ADMIN_PLUGIN] obj_a
			# Matches:
		    # Mani-Admin-Plugin messages

			$ev_obj_a  = $1;
			$ev_type = 500;
			$ev_status = &doEvent_Admin(
				"Mani Admin Plugin",
				substr($ev_obj_a, 0, 255)
			);
		} elsif ($s_output =~ /^\[BeetlesMod\]\s*(.+)$/) {
			# Prototype: Cmd:[BeetlesMod] obj_a
			# Matches:
		    # Beetles Mod messages
			
			$ev_obj_a  = $1;
			$ev_type = 500;
			$ev_status = &doEvent_Admin(
				"Beetles Mod",
				substr($ev_obj_a, 0, 255)
			);
		} elsif ($s_output =~ /^\[ADMIN:(.+)\] ADMIN Command: \1 used command (.+)$/) {
			# Prototype: [ADMIN] obj_a
			# Matches:
		    # Admin Mod messages
			
			$ev_obj_a  = $1;
			$ev_obj_b  = $2;
			$ev_type = 500;
			$ev_status = &doEvent_Admin(
				"Admin Mod",
				substr($ev_obj_b, 0, 255),
				$ev_obj_a
			);
		} elsif ($g_servers{$s_addr}->{play_game} == DYSTOPIA()) {
				if ($s_output =~ /^weapon \{ steam_id: 'STEAM_\d+:(.+?)', weapon_id: (\d+), class: \d+, team: \d+, shots: \((\d+),(\d+)\), hits: \((\d+),(\d+)\), damage: \((\d+),(\d+)\), headshots: \((\d+),(\d+)\), kills: \(\d+,\d+\) \}$/ && $g_mode eq "Normal") {
			
				# Prototype: weapon { steam_id: 'STEAMID', weapon_id: X, class: X, team: X, shots: (X,X), hits: (X,X), damage: (X,X), headshots: (X,X), kills: (X,X) }
				# Matches:
				# 501. Statsme weaponstats (Dystopia)
		
				my $steamid = $1;
				my $weapon = $2;
				my $shots = $3 + $4;
				my $hits = $5 + $6;
				my $damage = $7 + $8;
				my $headshots = $9 + $10;
				my $kills = $11 + $12;
				
				$ev_type = 501;
				
				my $weapcode = $dysweaponcodes{$weapon};
				
				foreach $player (values(%g_players)) {
					if ($player->{uniqueid} eq $steamid) {
						$ev_status = &doEvent_Statsme(
							$player->{"userid"},
							$steamid,
							$weapcode,
							$shots,
							$hits,
							$headshots,
							$damage,
							$kills,
							0
						);
						last;
					}
				}
			} elsif ($s_output =~ /^(?:join|change)_class \{ steam_id: 'STEAM_\d+:(.+?)', .* (?:new_|)class: (\d+), .* \}$/ && $g_mode eq "Normal") {
				# Prototype: join_class { steam_id: 'STEAMID', team: X, class: Y, time: ZZZZZZZZZ }
				# Matches:
				#  6. Role Selection (Dystopia)
				
				my $steamid = $1;
				my $role = $2;
				$ev_type = 6;
				
				foreach $player (values(%g_players)) {
					if ($player->{uniqueid} eq $steamid) {
						$ev_status = &doEvent_RoleSelection(
							$player->{"userid"},
							$steamid,
							$role
						);
						last;
					}
				}
			} elsif ($s_output =~ /^objective \{ steam_id: 'STEAM_\d+:(.+?)', class: \d+, team: \d+, objective: '(.+?)', time: \d+ \}$/ && $g_mode eq "Normal") {
				# Prototype: objective { steam_id: 'STEAMID', class: X, team: X, objective: 'TEXT', time: X }
				# Matches:
				# 11. Player Action (Dystopia Objectives)
				
				my $steamid = $1;
				my $action = $2;
				foreach $player (values(%g_players)) {
					if ($player->{uniqueid} eq $steamid) {
						$ev_status = &doEvent_PlayerAction(
							$player->{"userid"},
							$steamid,
							$action
						);
						last;
					}
				}
			}
		}

		if ($ev_type) {
			if ($g_debug > 2) {
				print <<EOT
					type   = "$ev_type"
					team   = "$ev_team"
					player = "$ev_player"
					verb   = "$ev_verb"
					obj_a  = "$ev_obj_a"
					obj_b  = "$ev_obj_b"
					obj_c  = "$ev_obj_c"
					properties = "$ev_properties"
EOT
;
				while (my($key, $value) = each(%ev_properties)) {
					print "property: \"$key\" = \"$value\"\n";
				}
				
				while (my($key, $value) = each(%ev_player)) {
					print "player $key = \"$value\"\n";
				}
			}
			
			if ($ev_status ne "") {
				&printEvent($ev_type, $ev_status);
			} else {
				&printEvent($ev_type, "BAD DATA: $s_output");
			}
		} elsif (($s_output =~ /^Banid: "(.+?(?:<.+?>)*)" was (?:kicked and )?banned "for ([0-9]+).00 minutes" by "Console"$/) ||
				($s_output =~ /^Banid: "(.+?(?:<.+?>)*)" was (?:kicked and )?banned "(permanently)" by "Console"$/)) {
			
			# Prototype: "player" verb[properties]
    		# Banid: huaaa<1804><STEAM_0:1:10769><>" was kicked and banned "permanently" by "Console"
			
			$ev_player  = $1;
			$ev_bantime = $2;
			my $playerinfo = &getPlayerInfo($ev_player, 1);

			if ($ev_bantime eq "5") {
				&printEvent("BAN", "Auto Ban - ignored");
			} elsif ($playerinfo) {
				if (($g_global_banning > 0) && ($g_servers{$s_addr}->{ignore_nextban}->{$playerinfo->{"uniqueid"}} == 1)) {
					delete($g_servers{$s_addr}->{ignore_nextban}->{$playerinfo->{"uniqueid"}});
					&printEvent("BAN", "Global Ban - ignored");
				} elsif (!$g_servers{$s_addr}->{ignore_nextban}->{$playerinfo->{"uniqueid"}}) {
					my $p_steamid  = $playerinfo->{"uniqueid"};
					my $player_obj = lookupPlayer($s_addr, $playerId, $p_steamid);
					&printEvent("BAN", "Steamid: ".$p_steamid);

					if ($player_obj) {
						$player_obj->{"is_banned"} = 1;
					}  
					if (($p_steamid ne "") && ($playerinfo->{"is_bot"} == 0) && ($playerinfo->{"userid"} > 0)) {
						if ($g_global_banning > 0) {
							if ($ev_bantime eq "permanently") {
								&printEvent("BAN", "Hide player!");
								&execNonQuery("UPDATE hlstats_Players SET hideranking=2 WHERE playerId IN (SELECT playerId FROM hlstats_PlayerUniqueIds WHERE uniqueId='".&quoteSQL($p_steamid)."')");
								$ev_bantime = 0;
							}
							my $pl_steamid  = $playerinfo->{"plain_uniqueid"};
							while (my($addr, $server) = each(%g_servers)) {
								if ($addr ne $s_addr) {
									&printEvent("BAN", "Global banning on ".$addr);
									$server->{ignore_nextban}->{$p_steamid} = 1;
									$server->dorcon("banid ".$ev_bantime." $pl_steamid");
									$server->dorcon("writeid");
								}  
							}
						} 
					}  
				}  
			} else {
				&printEvent("BAN", "No playerinfo");
			}
			&printEvent("BAN", $s_output);
		} else {
			# Unrecognized event
			# HELLRAISER
			if ($g_debug > 1) {
				&printEvent(999, "UNRECOGNIZED: " . $s_output);
			}
		}
		
		if (!$g_stdin && defined($g_servers{$s_addr}) && $ev_daemontime > $g_servers{$s_addr}->{next_plyr_flush}) {
			&printEvent("MYSQL", "Flushing player updates to database...",1);
			if ($g_servers{$s_addr}->{"srv_players"}) {
				while ( my($pl, $player) = each(%{$g_servers{$s_addr}->{"srv_players"}}) ) {
					if ($player->{needsupdate}) {
						$player->flushDB();
					}
				}
			}
			&printEvent("MYSQL", "Flushing player updates to database is complete.",1);
			
			$g_servers{$s_addr}->{next_plyr_flush} = $ev_daemontime + 15+int(rand(15));
		}

		if (($g_stdin == 0) && defined($g_servers{$s_addr})) {
			$s_lines = $g_servers{$s_addr}->{lines};
			# get ping from players
			if ($s_lines % 1000 == 0) {
				$g_servers{$s_addr}->update_players_pings();
			}

			if ($g_servers{$s_addr}->{show_stats} == 1) {
				# show stats
				if ($s_lines % 2500 == 40) {
					$g_servers{$s_addr}->dostats();
				}
			}
		
			if ($s_lines > 500000)	{
				$g_servers{$s_addr}->set("lines", 0);	
			}  else	{
				$g_servers{$s_addr}->increment("lines");	
			} 
		}
	} else {
		$s_addr = "";
	}
	} # end per-packet for loop

	while( my($server) = each(%g_servers))
	{	
		if($g_servers{$server}->{next_timeout}<$ev_daemontime)
		{
			#print "checking $ev_unixtime\n";
			# Clean up
			# look
			if($g_servers{$server}->{"srv_players"})
			{
				my %players_temp=%{$g_servers{$server}->{"srv_players"}};
				while ( my($pl, $player) = each(%players_temp) ) {
					my $timeout = 250; # 250;
					if ($g_mode eq "LAN")  {
						$timeout = $timeout * 2;
					}
					my $userid = $player->{userid};
					my $uniqueid = $player->{uniqueid};
					if ( ($ev_daemontime - $player->{timestamp}) > $timeout ) {
						#printf("%s - %s %s\n",$server, $player->{userid}, $player->{uniqueid});
						# we delete any player who is inactive for over $timeout sec
						# - they probably disconnected silently somehow.
						if (($player->{is_bot} == 0) || ($g_stdin)) {
							&printEvent(400, "Auto-disconnecting " . $player->getInfoString() ." for idling (" . ($ev_daemontime - $player->{timestamp}) . " sec) on server (".$server.")");
							removePlayer($server, $userid, $uniqueid);
						}
					}
				}
			}
			$g_servers{$server}->{next_timeout}=$ev_daemontime+30+rand(30);
		}
		
		if ($ev_daemontime > $g_servers{$server}->{next_flush}
			&& $g_servers{$server}->{needsupdate}
			)
		{
			$g_servers{$server}->flushDB();
			$g_servers{$server}->{next_flush} = $ev_daemontime + 20;
		}
	}

	while ( my($pl, $player) = each(%g_preconnect) ) {
		my $timeout = 600;
		if ( ($ev_daemontime - $player->{"timestamp"}) > $timeout ) {
			&printEvent(401, "Clearing pre-connect entry with key ".$pl);
			delete($g_preconnect{$pl});
		}
	}
	
	if ($g_stdin == 0) {
		# Track the Trend
		if ($g_track_stats_trend > 0) {
			track_hlstats_trend();
		}  
		while (my($addr, $server) = each(%g_servers)) {
			if (defined($server)) {
				$server->track_server_load();
			}
		}
		
		while( my($table) = each(%g_eventtable_data))
		{
			if ($g_eventtable_data{$table}{lastflush} + 30 < $ev_daemontime)
			{
				flushEventTable($table);
			}
		}

		# Same 30s gate as the event tables above. Ungated, this pass runs on
		# nearly every outer-loop iteration during a live match, which is the
		# per-frag UPDATE pattern the accumulators exist to batch away.
		# Shutdown and pre-aggregation call flushAccumulators() directly and
		# must stay ungated.
		if ($g_accum_lastflush + 30 < $ev_daemontime)
		{
			flushAccumulators();
			$g_accum_lastflush = $ev_daemontime;
		}

		# Write-path health, every 5 minutes and only when there is something to
		# say. A counter nobody reads is the same as no counter, and these three
		# are the ones that were silent through the LAN.
		if ($g_ktp_lasthealth + 300 < $ev_daemontime)
		{
			$g_ktp_lasthealth = $ev_daemontime;
			my $unresolved = scalar(keys %g_ktpUnresolvedActions);
			if ($g_sql_error_count || $g_sql_retry_count || $unresolved)
			{
				&printEvent("KTP_HEALTH",
					"sql_failed=$g_sql_error_count sql_retried=$g_sql_retry_count " .
					"unresolved_actions=$unresolved", 1);
			}
		}

		if ($timeout > 0 && $timeout % 60 == 0) {
			while (my($map_addr, $map_server) = each(%g_servers)) {
				if (defined($map_server) && $map_server->{map} eq "") {
					$map_server->get_map();
				}
			}
		}
	}  
	
	$c++;
	$c = 1 if ($c > 500000);
	$import_logs_count++ if ($g_stdin);
}

$end_time = time();
if ($g_stdin) {
	if ($import_logs_count > 0) {
		print "\n";
	}
	
	&flushAll(1);
	&execNonQuery("UPDATE hlstats_Players SET last_event=UNIX_TIMESTAMP();");
	&printEvent("IMPORT", "Import of log file complete. Scanned ".$import_logs_count." lines in ".($end_time-$start_time)." seconds", 1, 1);
}

#
# KTP: Map a KTPMatchHandler half string to the half column's numbering.
# "1st"/"1st half" -> 1, "2nd" -> 2, "OTn" -> 2+n. Both KTP_MATCH_START and
# KTP_HALF_END parse the same field, and this used to be copy-pasted in each —
# nothing kept the two copies in step if the numbering ever changed.
#
sub parseHalfNumber
{
	my ($half) = @_;

	return 1 if (!defined($half));
	return 1 if ($half =~ /^1/);
	return 2 if ($half =~ /^2/);
	return 2 + $1 if ($half =~ /^OT(\d+)/);
	return 1;
}

#
# KTP: Report an action the log carried but hlstats_Actions cannot resolve.
#
# The upstream handler skips such an event with no error, no counter and no log
# line. At the Philly 2026 LAN the actions table was never seeded, so every
# dod_control_point and dod_capture_area of the weekend was parsed, dropped, and
# never missed until the objective columns turned up empty afterwards.
#
# Warn on the first sighting of each distinct action and tally the rest, so a
# misconfiguration is loud once rather than either silent or unreadable.
#
sub ktpWarnUnresolvedAction
{
	my ($game, $action) = @_;
	return unless (defined($action) && $action ne "");
	$game = "?" unless defined($game);

	my $key = "$game/$action";
	if (!$g_ktpUnresolvedActions{$key}++) {
		&printEvent("SQL_ERROR",
			"Unresolved action '$action' (game '$game') is NOT in hlstats_Actions -- " .
			"this event is being DISCARDED and will never reach the database. " .
			"Seed the actions table for this game.", 1);
	}
}

#
# KTP: Warn if hlstats_Actions is empty for a game we are about to serve.
#
# Cheap to check once per game at discovery, and it turns a whole weekend of
# silently dropped objectives into one line at startup.
#
sub ktpAssertActionsSeeded
{
	my ($game) = @_;
	return unless defined($game);

	my $result = &doQuery("
		SELECT COUNT(*) FROM hlstats_Actions WHERE game = '" . &quoteSQL($game) . "'
	");
	my ($count) = $result->fetchrow_array;
	$result->finish;

	if (!$count) {
		&printEvent("SQL_ERROR",
			"hlstats_Actions has NO rows for game '$game'. Every objective event for " .
			"this game will be parsed and then discarded. Seed the actions table " .
			"before running a match.", 1);
	} else {
		&printEvent("HLSTATSX", "Actions loaded for game '$game': $count", 1);
	}
}

# BEGIN KTP SIDE-EFFECT-FREE PLAYER IDENTITY
# Buffered control-plane markers may arrive after a reconnect reused the same
# Steam id with a new engine userid. getPlayerInfo(create=0) is not read-only:
# it disconnects that newer object when userids differ. Parse and resolve these
# identities without touching the live player hash.
sub ktpParsePlayerIdentity
{
	my ($player) = @_;
	return undef
		if (!defined($player) ||
			$player !~ /^(.*?)<(\d+)><([^<>]*)><([^<>]*)>(?:<([^<>]*)>)?.*$/);

	my ($name, $userid, $uniqueid, $team, $role) = ($1, $2, $3, $4, $5);
	return undef if ($uniqueid eq "Console" && $team eq "Console");

	$uniqueid =~ s!\[U:1:(\d+)\]!'STEAM_0:'.($1 % 2).':'.int($1 / 2)!eg;
	$uniqueid =~ s/^STEAM_[0-9]+?\://;
	my $bot = botidcheck($uniqueid);

	if ($g_mode eq "NameTrack") {
		$uniqueid = $name;
	} elsif ($bot) {
		my $md5 = Digest::MD5->new;
		$md5->add($name);
		$md5->add($s_addr);
		$uniqueid = "BOT:" . $md5->hexdigest;
	} elsif ($g_mode eq "LAN") {
		# Normal getPlayerInfo recovers a LAN identity through mutable connection
		# state/IP caches. A delayed marker must not consult or modify those caches.
		return undef;
	}

	return undef
		if ($uniqueid eq "" || $uniqueid eq "UNKNOWN" ||
			$uniqueid eq "STEAM_ID_PENDING" || $uniqueid eq "STEAM_ID_LAN" ||
			$uniqueid eq "VALVE_ID_PENDING" || $uniqueid eq "VALVE_ID_LAN");

	return {
		name => $name,
		userid => $userid,
		uniqueid => $uniqueid,
		team => $team,
		role => $role,
		is_bot => $bot,
	};
}

sub ktpResolvePlayerIdentity
{
	my ($identity) = @_;
	return 0 if (!defined($identity));

	# Exact userid+uniqueid is safe. A different current userid for the same
	# uniqueid is deliberately ignored and the durable DB mapping is read.
	my $live = lookupPlayer($s_addr, $identity->{userid}, $identity->{uniqueid});
	return $live->{playerid} if ($live && $live->{playerid});
	return &getPlayerId($identity->{uniqueid});
}

sub ktpIdentityForGenericAction
{
	my ($identity, $player_id) = @_;
	return undef if (!defined($identity) || !defined($player_id) || $player_id < 1);

	# Generic action handlers still accept engine userid + stable identity.  If
	# this buffered marker predates a reconnect, select the current tuple only
	# when both stable identity and durable player id agree.  Return a copy so
	# neither parsing nor dispatch can mutate the live reconnect object.
	my $players = $g_servers{$s_addr}->{srv_players};
	if (defined($players)) {
		foreach my $key (keys %{$players}) {
			my $live = $players->{$key};
			next if (!defined($live) || !defined($live->{playerid}) ||
				!defined($live->{uniqueid}) || !defined($live->{userid}));
			next if (int($live->{playerid}) != int($player_id) ||
				$live->{uniqueid} ne $identity->{uniqueid});
			my %resolved = %{$identity};
			$resolved{userid} = $live->{userid};
			return \%resolved;
		}
	}

	return { %{$identity} };
}
# END KTP SIDE-EFFECT-FREE PLAYER IDENTITY

# BEGIN KTP LIFE BOUNDARY VALIDATION
# Keep this validation pure: scripts/selftest-life-boundary.pl extracts and
# executes the shipped implementation directly, so the test cannot drift into
# a second, more-permissive copy of the contract.
sub ktpValidateLifeBoundaryPayload
{
	my ($matchid, $producer_half, $kind, $reason, $team, $player_class, $player_slot,
		$round_live, $game_time, $event_epoch) = @_;

	return "missing matchid"
		if (!defined($matchid) || $matchid eq "");
	return "invalid matchid"
		if (length($matchid) > 64 ||
			$matchid !~ /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$/);
	return "invalid producer half"
		if (!defined($producer_half) || $producer_half !~ /^\d+$/ ||
			$producer_half < 1 || $producer_half > 255);

	return "invalid boundary kind"
		if (!defined($kind) || $kind !~ /^(?:start|end)$/);
	return "invalid boundary reason"
		if (!defined($reason) || $reason !~ /^(?:spawn|context_live|death|disconnect)$/);
	return "invalid kind/reason pair"
		if (($kind eq "start" && $reason !~ /^(?:spawn|context_live)$/) ||
			($kind eq "end" && $reason !~ /^(?:death|disconnect)$/));

	return "invalid team"
		if (!defined($team) || $team !~ /^[0-2]$/);
	return "invalid round_live"
		if (defined($round_live) && $round_live ne "" && $round_live !~ /^[01]$/);
	return "invalid game_time"
		if (!defined($game_time) ||
			$game_time !~ /^(?:0|[1-9]\d{0,7})(?:\.\d{1,2})?$/);
	return "invalid event_epoch"
		if (!defined($event_epoch) || $event_epoch !~ /^[1-9]\d{0,18}$/);

	# Class and slot are useful correlation context, but nullable by schema so
	# a future/older emitter can omit them without losing the durable boundary.
	# If present, however, malformed values reject the whole marker rather than
	# being silently coerced into a plausible player state.
	return "invalid player class"
		if (defined($player_class) && $player_class ne "" &&
			($player_class !~ /^\d+$/ || $player_class > 255));
	return "invalid player slot"
		if (defined($player_slot) && $player_slot ne "" &&
			($player_slot !~ /^\d+$/ || $player_slot < 1 || $player_slot > 32));

	return "";
}

sub ktpValidateProducerEventClock
{
	my ($matchid, $producer_half, $game_time, $event_epoch) = @_;
	return "invalid matchid"
		if (!defined($matchid) || length($matchid) > 64 ||
			$matchid !~ /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$/);
	return "invalid producer half"
		if (!defined($producer_half) || $producer_half !~ /^\d+$/ ||
			$producer_half < 1 || $producer_half > 255);
	return "invalid game_time"
		if (!defined($game_time) ||
			$game_time !~ /^(?:0|[1-9]\d{0,7})(?:\.\d{1,2})?$/);
	return "invalid event_epoch"
		if (!defined($event_epoch) || $event_epoch !~ /^[1-9]\d{0,18}$/);
	return "";
}
# END KTP LIFE BOUNDARY VALIDATION

# BEGIN KTP LIFE BOUNDARY CONTEXT
sub ktpResolveProducerEventContext
{
	my ($explicit_matchid, $explicit_half, $event_epoch) = @_;

	return (undef, undef, "server context unavailable", undef)
		if (!defined($g_servers{$s_addr}) ||
			!defined($g_servers{$s_addr}->{'id'}));
	return (undef, undef, "invalid producer context key", undef)
		if (!defined($explicit_matchid) || length($explicit_matchid) > 64 ||
			$explicit_matchid !~ /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$/ ||
			!defined($explicit_half) || $explicit_half !~ /^\d+$/ ||
			$explicit_half < 1 || $explicit_half > 255 ||
			!defined($event_epoch) || $event_epoch !~ /^[1-9]\d{0,18}$/);

	# Receipt-time daemon memory is deliberately irrelevant: buffered UDP lines
	# can arrive in a later half. Resolve the producer's exact match+half+clock
	# against the persisted interval that contained the event. The DB collation
	# is case-insensitive, so compare returned ids byte-for-byte in Perl.
	my $server_id = $g_servers{$s_addr}->{'id'};
	my $cache_key = join("\x1e", int($server_id), $explicit_matchid,
		int($explicit_half));
	if (defined($g_ktpProducerContextCache{$cache_key})) {
		my $cached = $g_ktpProducerContextCache{$cache_key};
		my $upper_epoch = defined($cached->{end_epoch})
			? $cached->{end_epoch} : $cached->{proof_epoch};
		if ($event_epoch >= $cached->{start_epoch} &&
			$event_epoch <= $upper_epoch) {
			return ($cached->{half}, $cached->{map}, "", "event-time-interval-cache");
		}
	}
	my $result = &doQuery("
		SELECT match_id, half, map_name,
		       UNIX_TIMESTAMP(start_time) AS start_epoch,
		       UNIX_TIMESTAMP(end_time) AS end_epoch,
		       UNIX_TIMESTAMP() AS proof_epoch
		FROM ktp_matches
		WHERE server_id = ".int($server_id)."
		  AND match_id = '".&quoteSQL($explicit_matchid)."'
		  AND start_time <= FROM_UNIXTIME(".int($event_epoch).")
		  AND (end_time IS NULL OR end_time >= FROM_UNIXTIME(".int($event_epoch)."))
		ORDER BY half
	");

	my @intervals = ();
	while (my $row = $result->fetchrow_hashref()) {
		push @intervals, $row;
	}
	$result->finish();

	foreach my $row (@intervals) {
		return (undef, undef, "matchid case mismatch", undef)
			if (!defined($row->{match_id}) || $row->{match_id} ne $explicit_matchid);
	}
	return (undef, undef,
		"found ".scalar(@intervals)." event-time match intervals", undef)
		if (scalar(@intervals) != 1);

	my $row = $intervals[0];
	return (undef, undef, "event-time row has invalid half", undef)
		if (!defined($row->{half}) || $row->{half} !~ /^\d+$/ ||
			$row->{half} < 1 || $row->{half} > 255);
	return (undef, undef, "producer half disagrees with event-time interval", undef)
		if (int($row->{half}) != int($explicit_half));
	return (undef, undef, "event-time row has invalid map", undef)
		if (!defined($row->{map_name}) || $row->{map_name} eq "" ||
			length($row->{map_name}) > 32);
	return (undef, undef, "event-time row has invalid interval clock", undef)
		if (!defined($row->{start_epoch}) || $row->{start_epoch} !~ /^\d+$/ ||
			!defined($row->{proof_epoch}) || $row->{proof_epoch} !~ /^\d+$/ ||
			(defined($row->{end_epoch}) && $row->{end_epoch} !~ /^\d+$/) ||
			$row->{start_epoch} > $row->{proof_epoch} ||
			(defined($row->{end_epoch}) &&
				($row->{end_epoch} < $row->{start_epoch} ||
				 $row->{end_epoch} > $row->{proof_epoch})));
	# An open interval proves membership only through the database's own NOW().
	# Do not accept clock skew or a forged future epoch on the query miss that
	# creates the cache entry; cache hits enforce the identical proof horizon.
	return (undef, undef, "producer epoch exceeds open-interval proof horizon", undef)
		if (!defined($row->{end_epoch}) && $event_epoch > $row->{proof_epoch});

	# Bound process-lifetime memory without weakening the proof: only successful
	# interval tuples are cached, and clearing simply causes another DB proof.
	%g_ktpProducerContextCache = ()
		if (scalar(keys %g_ktpProducerContextCache) >= 512 &&
			!defined($g_ktpProducerContextCache{$cache_key}));
	$g_ktpProducerContextCache{$cache_key} = {
		half => int($row->{half}), map => $row->{map_name},
		start_epoch => int($row->{start_epoch}),
		end_epoch => defined($row->{end_epoch}) ? int($row->{end_epoch}) : undef,
		proof_epoch => int($row->{proof_epoch})
	};
	return (int($row->{half}), $row->{map_name}, "", "event-time-interval");
}

sub ktpResolveValidatedProducerEventContext
{
	my ($matchid, $producer_half, $game_time, $event_epoch) = @_;
	my $validation_error = ktpValidateProducerEventClock(
		$matchid, $producer_half, $game_time, $event_epoch);
	return (undef, undef, $validation_error, undef)
		if ($validation_error ne "");
	return ktpResolveProducerEventContext($matchid, $producer_half, $event_epoch);
}

sub ktpHasExplicitProducerContext
{
	my ($matchid) = @_;
	return defined($matchid) && $matchid ne "" && $matchid ne "-";
}

sub ktpWarnProducerClock
{
	my ($marker, $error) = @_;
	my $key = join("\x1e", $s_addr, $marker, $error);
	my $count = ++$g_ktpCaptureClockWarnings{$key};
	# First occurrence is immediately visible; thereafter aggregate one journal
	# line per 1000 failures instead of one per damage hit.
	return if ($count != 1 && ($count % 1000) != 0);
	&printEvent("KTP_".uc($marker)."_CLOCK_DROP",
		"$marker authoritative clocks suppressed ($count occurrences): $error; preserving legacy facts",
		1, 1);
}
# END KTP LIFE BOUNDARY CONTEXT

sub doEvent_KTPLifeBoundary
{
	my ($player_id, $engine_userid, $matchid, $producer_half, $kind, $reason, $team,
		$player_class, $player_slot, $round_live, $game_time, $event_epoch) = @_;

	my $validation_error = ktpValidateLifeBoundaryPayload(
		$matchid, $producer_half, $kind, $reason, $team, $player_class, $player_slot,
		$round_live, $game_time, $event_epoch);
	if ($validation_error ne "") {
		&printEvent("KTP_LIFE_DROP", "Life boundary dropped: $validation_error", 1, 1);
		return "Life boundary dropped: $validation_error";
	}
	if (!defined($player_id) || $player_id !~ /^\d+$/ || $player_id < 1) {
		&printEvent("KTP_LIFE_DROP", "Life boundary dropped: invalid resolved player", 1, 1);
		return "Life boundary dropped: invalid resolved player";
	}

	my ($half, $map, $context_error, $context_source) =
		ktpResolveProducerEventContext($matchid, $producer_half, $event_epoch);
	if ($context_error ne "") {
		&printEvent("KTP_LIFE_DROP",
			"Life boundary dropped: $context_error (match=$matchid player=$player_id)",
			1, 1);
		return "Life boundary dropped: $context_error";
	}

	my $server_id = $g_servers{$s_addr}->{'id'};
	my $slot_sql = (defined($player_slot) && $player_slot ne "")
		? int($player_slot) : "NULL";
	my $class_sql = (defined($player_class) && $player_class ne "")
		? int($player_class) : "NULL";
	my $userid_sql = (defined($engine_userid) && $engine_userid =~ /^\d+$/)
		? int($engine_userid) : "NULL";
	# V1 deliberately leaves this NULL. MatchHandler pauses stats through a
	# private DODX flag that the plugin cannot observe, and daemon state at
	# receipt time is unsafe because this marker is buffered. Retain the nullable
	# column for a future emitter that can provide an authoritative snapshot.
	my $round_live_sql = (defined($round_live) && $round_live ne "")
		? int($round_live) : "NULL";
	my $normalized_game_time = sprintf("%.2f", $game_time + 0);

	# game_time participates in the natural key because event_epoch has only
	# one-second precision. INSERT IGNORE makes a duplicated UDP/replay marker a
	# no-op while keeping two genuine same-second boundaries distinct.
	my $rv = &execNonQuery("
		INSERT IGNORE INTO ktp_life_events
			(server_id, match_id, half, map_name, player_id, player_slot,
			 engine_userid, boundary_kind, reason, team, player_class,
			 round_live, game_time, event_epoch, event_time)
		VALUES
			(".int($server_id).", '".&quoteSQL($matchid)."', ".int($half).",
			 '".&quoteSQL($map)."', ".int($player_id).", $slot_sql,
			 $userid_sql, '".&quoteSQL($kind)."', '".&quoteSQL($reason)."',
			 ".int($team).", $class_sql, $round_live_sql,
			 $normalized_game_time, $event_epoch, FROM_UNIXTIME($event_epoch))
	");

	return "Life boundary SQL insert failed"
		if (!defined($rv));
	return "Life boundary duplicate ignored: match=$matchid half=$half player=$player_id kind=$kind reason=$reason"
		if (($rv + 0) == 0);
	return "Life boundary logged: match=$matchid half=$half player=$player_id kind=$kind reason=$reason context=$context_source";
}

sub doEvent_KTPAssist
{
	my ($assister_id, $victim_id, $matchid, $producer_half, $event_epoch,
		$game_time, $assister_position, $victim_position) = @_;

	my $validation_error = ktpValidateProducerEventClock(
		$matchid, $producer_half, $game_time, $event_epoch);
	if ($validation_error ne "") {
		&printEvent("KTP_ASSIST_DROP", "Canonical assist dropped: $validation_error", 1, 1);
		return "Canonical assist dropped: $validation_error";
	}
	return "Canonical assist dropped: invalid resolved player"
		if (!defined($assister_id) || $assister_id !~ /^\d+$/ || $assister_id < 1 ||
			!defined($victim_id) || $victim_id !~ /^\d+$/ || $victim_id < 1);

	my ($half, $map, $context_error, $context_source) =
		ktpResolveProducerEventContext($matchid, $producer_half, $event_epoch);
	if ($context_error ne "") {
		&printEvent("KTP_ASSIST_DROP",
			"Canonical assist dropped: $context_error (match=$matchid assister=$assister_id victim=$victim_id)",
			1, 1);
		return "Canonical assist dropped: $context_error";
	}

	my ($apos_x, $apos_y, $apos_z) = ("NULL", "NULL", "NULL");
	if (defined($assister_position) &&
		$assister_position =~ /^(-?\d+)\s+(-?\d+)\s+(-?\d+)$/) {
		($apos_x, $apos_y, $apos_z) = (int($1), int($2), int($3));
	}
	my ($vpos_x, $vpos_y, $vpos_z) = ("NULL", "NULL", "NULL");
	if (defined($victim_position) &&
		$victim_position =~ /^(-?\d+)\s+(-?\d+)\s+(-?\d+)$/) {
		($vpos_x, $vpos_y, $vpos_z) = (int($1), int($2), int($3));
	}

	my $server_id = $g_servers{$s_addr}->{'id'};
	my $normalized_game_time = sprintf("%.2f", $game_time + 0);
	my $rv = &execNonQuery("
		INSERT IGNORE INTO ktp_assist_events
			(server_id, match_id, half, map_name, assister_id, victim_id,
			 assister_pos_x, assister_pos_y, assister_pos_z,
			 victim_pos_x, victim_pos_y, victim_pos_z,
			 game_time, event_epoch, event_time)
		VALUES
			(".int($server_id).", '".&quoteSQL($matchid)."', ".int($half).",
			 '".&quoteSQL($map)."', ".int($assister_id).", ".int($victim_id).",
			 $apos_x, $apos_y, $apos_z, $vpos_x, $vpos_y, $vpos_z,
			 $normalized_game_time, $event_epoch, FROM_UNIXTIME($event_epoch))
	");

	return "Canonical assist SQL insert failed" if (!defined($rv));
	return "Canonical assist duplicate ignored: match=$matchid half=$half assister=$assister_id victim=$victim_id"
		if (($rv + 0) == 0);
	return "Canonical assist logged: match=$matchid half=$half assister=$assister_id victim=$victim_id context=$context_source";
}

#
# KTP: Handle per-hit damage event.
#
sub doEvent_KTPDamage
{
	# KTP: Per-hit damage ledger. INSERTs directly into ktp_damage_events --
	# not one of the generic recordEvent-batched hlstats_Events_* tables,
	# since that machinery is config-driven around the stock event set and
	# this is a standalone KTP table. Same shape as doEvent_KTPMatchStart:
	# direct execNonQuery, not a queue.
	my ($attacker_id, $victim_id, $weapon, $damage, $damage_capped, $hitplace,
		$game_time, $event_epoch, $producer_matchid, $producer_half) = @_;

	return 0 if (!defined($attacker_id) || !defined($victim_id));

	my $server_id = $g_servers{$s_addr}->{'id'};

	# Same match_id/round_live gating recordEvent() uses -- only tag with
	# match_id while the round is live, so freeze-time and warmup damage
	# lands with match_id NULL rather than attributed to a match that isn't
	# actually running.
	my $match_id_sql = "NULL";
	my $half = 0;
	if (defined($g_ktpMatchContext{$s_addr}) && $g_ktpMatchContext{$s_addr}{match_id} ne "") {
		if (!defined($g_ktpMatchContext{$s_addr}{round_live}) || $g_ktpMatchContext{$s_addr}{round_live}) {
			$match_id_sql = "'".quoteSQL($g_ktpMatchContext{$s_addr}{match_id})."'";
			$half = $g_ktpMatchContext{$s_addr}{half_num} || 0;
		}
	}

	# Producer context is additive and must be the analytics join key. Keep the
	# historical receipt-time match_id/half gate above unchanged for compatibility.
	# Populate clocks only after the exact producer tuple is proven against one DB
	# interval; legacy/sentinel markers still keep their preexisting damage row.
	my $producer_match_sql = "NULL";
	my $producer_half_sql = "NULL";
	my $event_epoch_sql = "NULL";
	my $event_time_sql = "NOW()";
	my ($validated_half, $validated_map, $producer_context_source);
	my $producer_context_error = "legacy producer context absent";
	my $has_explicit_context = ktpHasExplicitProducerContext($producer_matchid);
	if ($has_explicit_context) {
		($validated_half, $validated_map, $producer_context_error,
			$producer_context_source) = ktpResolveValidatedProducerEventContext(
				$producer_matchid, $producer_half, $game_time, $event_epoch);
	}
	if ($producer_context_error eq "") {
		$producer_match_sql = "'".quoteSQL($producer_matchid)."'";
		$producer_half_sql = int($validated_half);
		$event_epoch_sql = $event_epoch;
		$event_time_sql = "FROM_UNIXTIME($event_epoch)";
	} elsif ($has_explicit_context) {
		ktpWarnProducerClock("damage", $producer_context_error);
	}

	&execNonQuery("
		INSERT INTO ktp_damage_events
			(server_id, match_id, half, attacker_id, victim_id, weapon,
			 damage, damage_capped, hitplace, producer_match_id, producer_half,
			 game_time, event_epoch, event_time)
		VALUES
			($server_id, $match_id_sql, $half, $attacker_id, $victim_id,
			 '".quoteSQL($weapon)."', ".int($damage).", ".int($damage_capped).",
			 ".int($hitplace).", $producer_match_sql, $producer_half_sql,
			 ".($game_time + 0).", $event_epoch_sql, $event_time_sql)
	");

	return "Damage logged: attacker=$attacker_id victim=$victim_id weapon=$weapon damage=$damage capped=$damage_capped";
}

sub doEvent_KTPPosition
{
	# KTP: periodic roster-position sample. Same match_id/round_live gating
	# recordEvent() and doEvent_KTPDamage use -- only tag with match_id while
	# the round is live, so warmup/freeze-time samples land with match_id
	# NULL rather than attributed to a match that isn't actually running.
	my ($player_id, $team, $position, $game_time) = @_;

	return 0 if (!defined($player_id));

	my $server_id = $g_servers{$s_addr}->{'id'};

	my $match_id_sql = "NULL";
	my $half = 0;
	if (defined($g_ktpMatchContext{$s_addr}) && $g_ktpMatchContext{$s_addr}{match_id} ne "") {
		if (!defined($g_ktpMatchContext{$s_addr}{round_live}) || $g_ktpMatchContext{$s_addr}{round_live}) {
			$match_id_sql = "'".quoteSQL($g_ktpMatchContext{$s_addr}{match_id})."'";
			$half = $g_ktpMatchContext{$s_addr}{half_num} || 0;
		}
	}

	# "X Y Z", same format/regex ksc_origin_str's callers already use
	# (frag_context's k_position/v_position). Never fabricate 0 0 0 -- if
	# the plugin-side read failed the marker wouldn't have this property at
	# all, but guard the parse anyway rather than trust an unvalidated string
	# straight into an INSERT.
	if ($position !~ /^(-?\d+)\s+(-?\d+)\s+(-?\d+)$/) {
		return "Position sample dropped for player=$player_id: unparseable position '$position'";
	}
	my ($x, $y, $z) = ($1, $2, $3);

	&execNonQuery("
		INSERT INTO ktp_position_samples
			(server_id, match_id, half, player_id, team, pos_x, pos_y, pos_z,
			 game_time, event_time)
		VALUES
			($server_id, $match_id_sql, $half, $player_id, ".int($team).",
			 $x, $y, $z, ".($game_time + 0).", NOW())
	");

	return "Position sample logged: player=$player_id team=$team pos=$x,$y,$z";
}

sub doEvent_KTPFlagCapture
{
	# KTP: per-player flag-capture completion. Same match_id/round_live
	# gating as doEvent_KTPPosition/doEvent_KTPDamage -- only tag with
	# match_id while the round is live, so warmup captures land with
	# match_id NULL rather than attributed to a match that isn't running.
	my ($player_id, $team, $flag_name) = @_;

	return 0 if (!defined($player_id));

	my $server_id = $g_servers{$s_addr}->{'id'};

	my $match_id_sql = "NULL";
	my $half = 0;
	if (defined($g_ktpMatchContext{$s_addr}) && $g_ktpMatchContext{$s_addr}{match_id} ne "") {
		if (!defined($g_ktpMatchContext{$s_addr}{round_live}) || $g_ktpMatchContext{$s_addr}{round_live}) {
			$match_id_sql = "'".quoteSQL($g_ktpMatchContext{$s_addr}{match_id})."'";
			$half = $g_ktpMatchContext{$s_addr}{half_num} || 0;
		}
	}

	my $flag_sql = defined($flag_name) && $flag_name ne "" ? "'".quoteSQL($flag_name)."'" : "NULL";
	my $team_sql = defined($team) && $team ne "" ? "'".quoteSQL($team)."'" : "NULL";

	&execNonQuery("
		INSERT INTO ktp_flag_captures
			(server_id, match_id, half, player_id, team, flag_name, event_time)
		VALUES
			($server_id, $match_id_sql, $half, $player_id, $team_sql, $flag_sql, NOW())
	");

	return "Flag capture logged: player=$player_id team=".($team // "?")." flag=".($flag_name // "?");
}

sub doEvent_KTPFlagPosition
{
	# KTP: static per-flag position, upserted into ktp_flag_positions.
	# Fires once per map load (controlpoints_init), including warmup and
	# halftime reloads -- harmless, this is idempotent on the unique key.
	my ($map, $flag_index, $flag_name, $x, $y) = @_;

	return 0 if (!defined($map) || $map eq "" || !defined($flag_index));

	my $server_id = $g_servers{$s_addr}->{'id'};

	&execNonQuery("
		INSERT INTO ktp_flag_positions
			(server_id, map_name, flag_index, flag_name, origin_x, origin_y)
		VALUES
			($server_id, '".quoteSQL($map)."', ".int($flag_index).",
			 '".quoteSQL($flag_name)."', ".int($x // 0).", ".int($y // 0)."
		)
		ON DUPLICATE KEY UPDATE
			flag_name = '".quoteSQL($flag_name)."',
			origin_x = ".int($x // 0).",
			origin_y = ".int($y // 0)."
	");

	return "Flag position recorded: map=$map flag_index=$flag_index name=$flag_name x=$x y=$y";
}

sub doEvent_KTPFlagState
{
	my ($map, $flag_index, $flag_name, $owner, $initial, $game_time) = @_;

	return "Flag state dropped: missing map or flag index"
		if (!defined($map) || $map eq "" || !defined($flag_index));
	return "Flag state dropped: invalid owner"
		if (!defined($owner) || $owner !~ /^\d+$/ || $owner < 0 || $owner > 2);

	# Unlike samples that may be useful for warmup diagnostics, ownership rows
	# exist only to reconstruct match intervals. Fail closed outside a live
	# match instead of creating ambiguous NULL-match history.
	return "Flag state ignored outside live match context"
		if (!defined($g_ktpMatchContext{$s_addr}) ||
			$g_ktpMatchContext{$s_addr}{match_id} eq "" ||
			(defined($g_ktpMatchContext{$s_addr}{round_live}) &&
			 !$g_ktpMatchContext{$s_addr}{round_live}));

	my $server_id = $g_servers{$s_addr}->{'id'};
	my $match_id = $g_ktpMatchContext{$s_addr}{match_id};
	my $half = $g_ktpMatchContext{$s_addr}{half_num} || 0;
	my $flag_sql = defined($flag_name) && $flag_name ne ""
		? "'".quoteSQL($flag_name)."'" : "NULL";
	my $initial_sql = $initial ? 1 : 0;
	my $game_time_sql = defined($game_time) ? ($game_time + 0) : 0;

	&execNonQuery("
		INSERT IGNORE INTO ktp_flag_state_events
			(server_id, match_id, half, map_name, flag_index, flag_name,
			 owner_team, is_initial, game_time, event_time)
		VALUES
			($server_id, '".quoteSQL($match_id)."', ".int($half).",
			 '".quoteSQL($map)."', ".int($flag_index).", $flag_sql,
			 ".int($owner).", $initial_sql, $game_time_sql, NOW())
	");

	return "Flag state logged: match=$match_id half=$half flag=$flag_index owner=$owner initial=$initial_sql";
}

sub doEvent_KTPMatchStart
{
	my ($matchid, $map, $half, $match_type) = @_;

	# KTP DEBUG: Log function entry
	&printEvent("KTP_DEBUG", "doEvent_KTPMatchStart CALLED: matchid='$matchid' map='$map' half='$half' type='$match_type' server='$s_addr'", 1);

	return 0 if (!defined($matchid) || $matchid eq "");
	# Fail closed for retention: an absent/invalid type remains NULL, which the
	# purge allowlist never selects. MatchHandler enum values are 0..5.
	my $match_type_sql = "NULL";
	if (defined($match_type) && $match_type =~ /^\d+$/ && $match_type >= 0 && $match_type <= 5) {
		$match_type_sql = int($match_type);
	}

	# Store match context for this server (used by recordEvent to tag kills)
	$g_ktpMatchContext{$s_addr} = {
		match_id => $matchid,
		match_type => ($match_type_sql eq "NULL" ? undef : $match_type_sql),
		map => $map,
		half => $half || "1",
		round_live => 1,  # KTP: Default to live; toggled by KTP_ROUND_FREEZE/KTP_ROUND_LIVE
		players_tracked => {}  # Track which players we've already recorded
	};

	# KTP: Also restore the server's map tracking variable.
	# This ensures the map is correct even after a daemon restart where the
	# "Started map" log event was missed. All frag events use get_map() which
	# reads $g_servers{$s_addr}->{map}, so we must keep it in sync.
	if (defined($map) && $map ne "" && defined($g_servers{$s_addr})) {
		$g_servers{$s_addr}->{map} = $map;
		&printEvent("KTP_DEBUG", "doEvent_KTPMatchStart: Restored server map to '$map'", 1);
	}

	# Get server ID
	my $server_id = $g_servers{$s_addr}->{'id'};

	my $half_num = parseHalfNumber($half);

	# KTP: Store half_num in match context for per-half event tracking
	$g_ktpMatchContext{$s_addr}{half_num} = $half_num;

	# KTP DEBUG: Log parsed half number
	&printEvent("KTP_DEBUG", "doEvent_KTPMatchStart: half_num=$half_num server_id=$server_id", 1);

	# If this is half 2 or later, close out the previous half's end_time
	if ($half_num > 1) {
		my $prev_half = $half_num - 1;
		&printEvent("KTP_DEBUG", "doEvent_KTPMatchStart: Closing previous half ($prev_half) for match $matchid", 1);
		&execNonQuery("
			UPDATE ktp_matches
			SET end_time = NOW()
			WHERE match_id = '".quoteSQL($matchid)."'
			AND server_id = $server_id
			AND half = $prev_half
			AND end_time IS NULL
		");
	}

	# Insert match record (no-op if already exists for this half — don't overwrite start_time)
	&execNonQuery("
		INSERT INTO ktp_matches (match_id, server_id, map_name, half, match_type, start_time)
		VALUES ('".quoteSQL($matchid)."', $server_id, '".quoteSQL($map)."', $half_num, $match_type_sql, NOW())
		ON DUPLICATE KEY UPDATE
			match_type = COALESCE(match_type, VALUES(match_type))
	");

	&printEvent("KTP", "Match started: $matchid on $map (half: $half)", 1);

	return 1;
}

#
# KTP: Track a player participating in the current match
# Called from doEvent_Frag for both killer and victim
#
sub ktpTrackMatchPlayer
{
	my ($player) = @_;

	# Skip if no active match context
	return 0 if (!defined($g_ktpMatchContext{$s_addr}) || $g_ktpMatchContext{$s_addr}{match_id} eq "");

	# Skip if player not valid
	return 0 if (!defined($player) || !defined($player->{playerid}));

	my $match_id = $g_ktpMatchContext{$s_addr}{match_id};
	my $player_id = $player->{playerid};
	my $steam_id = $player->{uniqueid} || "";
	my $player_name = $player->{name} || "";
	my $team = 0;

	# Map team name to number (1=Allies, 2=Axis for DoD)
	if (defined($player->{team})) {
		if ($player->{team} eq "Allies" || $player->{team} eq "allies") { $team = 1; }
		elsif ($player->{team} eq "Axis" || $player->{team} eq "axis") { $team = 2; }
	}

	# Skip if already tracked this player in this match (in-memory check for performance)
	my $track_key = "$player_id:$steam_id";
	return 1 if (defined($g_ktpMatchContext{$s_addr}{players_tracked}{$track_key}));
	$g_ktpMatchContext{$s_addr}{players_tracked}{$track_key} = 1;

	# Insert player into match_players (update team/name if already exists from earlier half)
	&execNonQuery("
		INSERT INTO ktp_match_players (match_id, player_id, steam_id, player_name, team, joined_at)
		VALUES ('".quoteSQL($match_id)."', $player_id, '".quoteSQL($steam_id)."', '".quoteSQL($player_name)."', $team, NOW())
		ON DUPLICATE KEY UPDATE team = VALUES(team), player_name = VALUES(player_name)
	");

	return 1;
}

# A context buffered just before KTP_MATCH_END can arrive after the canonical
# event tables were aggregated. Refresh only that killer's recently-ended
# cache rows; ordinary live contexts never enter this path.
sub ktpRefreshLateHeadshots
{
	my ($server_id, $player_id) = @_;

	&execNonQuery("
		UPDATE ktp_match_stats ms
		JOIN (
			SELECT f.match_id, f.half, f.killerId, SUM(f.headshot) AS headshots
			FROM hlstats_Events_Frags f
			JOIN ktp_matches m ON m.match_id = f.match_id
				AND m.server_id = $server_id AND m.half = f.half
			WHERE f.serverId = $server_id AND f.killerId = $player_id
				AND f.match_id IS NOT NULL
				AND m.end_time >= DATE_SUB(NOW(), INTERVAL 30 SECOND)
			GROUP BY f.match_id, f.half, f.killerId
		) canonical ON canonical.match_id = ms.match_id
			AND canonical.half = ms.half AND canonical.killerId = ms.player_id
		SET ms.headshots = canonical.headshots
		WHERE ms.half > 0
	");

	&execNonQuery("
		UPDATE ktp_match_stats total
		JOIN (
			SELECT part.match_id, part.player_id, SUM(part.headshots) AS headshots
			FROM ktp_match_stats part
			JOIN ktp_matches m ON m.match_id = part.match_id
				AND m.server_id = $server_id AND m.half = part.half
			WHERE part.player_id = $player_id AND part.half > 0
				AND m.end_time >= DATE_SUB(NOW(), INTERVAL 30 SECOND)
			GROUP BY part.match_id, part.player_id
		) halves ON halves.match_id = total.match_id
			AND halves.player_id = total.player_id
		SET total.headshots = halves.headshots
		WHERE total.half = 0
	");
}

#
# KTP: Handle KTP_MATCH_END event
# Aggregates per-half and total stats from event tables into ktp_match_stats
#
sub doEvent_KTPMatchEnd
{
	my ($matchid, $map) = @_;

	return 0 if (!defined($matchid) || $matchid eq "");

	# Get server ID
	my $server_id = $g_servers{$s_addr}->{'id'};

	# KTP: Flush all pending event queues and accumulators before aggregation
	# With queue size 100, up to 100 kills could be in-memory when match ends
	flushEventTable("Frags");
	flushEventTable("Teamkills");
	flushEventTable("Suicides");
	flushEventTable("Statsme");
	flushAccumulators();

	# Get all halves recorded for this match
	my @halves = ();
	my $q_matchid = quoteSQL($matchid);
	my $result = &doQuery("
		SELECT half FROM ktp_matches
		WHERE match_id = '$q_matchid' AND server_id = $server_id
		ORDER BY half
	");
	if ($result) {
		while (my $row = $result->fetchrow_hashref()) {
			push @halves, $row->{half};
		}
	}
	@halves = (0) if (scalar(@halves) == 0);

	&printEvent("KTP_DEBUG", "doEvent_KTPMatchEnd: match=$matchid halves=[@halves]", 1);

	# Aggregate per-half stats from canonical event tables into ktp_match_stats.
	# Damage comes from the per-hit KTP ledger, not StatsMe: StatsMe is a
	# player/weapon accumulator flush whose match attribution depends on flush
	# timing, while ktp_damage_events is recorded at hit time with match + half.
	# damage_capped is the competitive damage definition (actual useful HP,
	# capped at 100 per hit), shared with composite_v2.
	foreach my $half_num (@halves) {
		&execNonQuery("
			INSERT INTO ktp_match_stats
				(match_id, player_id, half, kills, deaths, headshots,
				 team_kills, suicides, damage, score)
			SELECT
				'$q_matchid', p.playerId, $half_num,
				COALESCE(k.kills, 0), COALESCE(d.deaths, 0),
				COALESCE(k.headshots, 0), COALESCE(tk.team_kills, 0),
				COALESCE(s.suicides, 0), COALESCE(dmg.damage, 0), 0
			FROM ktp_match_players mp
			JOIN hlstats_Players p ON mp.player_id = p.playerId
			LEFT JOIN (
				SELECT killerId, COUNT(*) as kills, SUM(headshot) as headshots
				FROM hlstats_Events_Frags
				WHERE match_id = '$q_matchid' AND half = $half_num
				GROUP BY killerId
			) k ON p.playerId = k.killerId
			LEFT JOIN (
				SELECT victimId, COUNT(*) as deaths
				FROM hlstats_Events_Frags
				WHERE match_id = '$q_matchid' AND half = $half_num
				GROUP BY victimId
			) d ON p.playerId = d.victimId
			LEFT JOIN (
				SELECT killerId, COUNT(*) as team_kills
				FROM hlstats_Events_Teamkills
				WHERE match_id = '$q_matchid' AND half = $half_num
				GROUP BY killerId
			) tk ON p.playerId = tk.killerId
			LEFT JOIN (
				SELECT playerId, COUNT(*) as suicides
				FROM hlstats_Events_Suicides
				WHERE match_id = '$q_matchid' AND half = $half_num
				GROUP BY playerId
			) s ON p.playerId = s.playerId
			LEFT JOIN (
				SELECT attacker_id AS playerId, SUM(damage_capped) as damage
				FROM ktp_damage_events
				WHERE match_id = '$q_matchid' AND half = $half_num
				GROUP BY attacker_id
			) dmg ON p.playerId = dmg.playerId
			WHERE mp.match_id = '$q_matchid'
			ON DUPLICATE KEY UPDATE
				kills = VALUES(kills), deaths = VALUES(deaths),
				headshots = VALUES(headshots), team_kills = VALUES(team_kills),
				suicides = VALUES(suicides), damage = VALUES(damage)
		");

		# Update score from in-memory accumulator
		if (defined($g_ktpScoreAccum{$matchid})) {
			foreach my $pid (keys %{$g_ktpScoreAccum{$matchid}}) {
				my $sc = $g_ktpScoreAccum{$matchid}{$pid}{$half_num} || 0;
				next if ($sc == 0);
				&execNonQuery("
					UPDATE ktp_match_stats SET score = $sc
					WHERE match_id = '$q_matchid'
					AND player_id = $pid AND half = $half_num
				");
			}
		}
	}

	# Insert total row (half=0) by summing per-half rows
	if ($halves[0] != 0) {
		&execNonQuery("
			INSERT INTO ktp_match_stats
				(match_id, player_id, half, kills, deaths, headshots,
				 team_kills, suicides, damage, score)
			SELECT match_id, player_id, 0,
				SUM(kills), SUM(deaths), SUM(headshots),
				SUM(team_kills), SUM(suicides), SUM(damage), SUM(score)
			FROM ktp_match_stats
			WHERE match_id = '$q_matchid' AND half > 0
			GROUP BY match_id, player_id
			ON DUPLICATE KEY UPDATE
				kills = VALUES(kills), deaths = VALUES(deaths),
				headshots = VALUES(headshots), team_kills = VALUES(team_kills),
				suicides = VALUES(suicides), damage = VALUES(damage),
				score = VALUES(score)
		");
	}

	# Clean up score accumulator for this match
	delete $g_ktpScoreAccum{$matchid};

	# Update match end time for most recent record with this match_id
	&execNonQuery("
		UPDATE ktp_matches
		SET end_time = NOW()
		WHERE match_id = '$q_matchid'
		AND server_id = $server_id
		AND end_time IS NULL
		ORDER BY start_time DESC
		LIMIT 1
	");

	# Clear match context for this server
	if (defined($g_ktpMatchContext{$s_addr})) {
		&printEvent("KTP_DEBUG", "doEvent_KTPMatchEnd: Clearing match context for $s_addr (was match_id='$g_ktpMatchContext{$s_addr}{match_id}')", 1);
		delete $g_ktpMatchContext{$s_addr};
	}

	&printEvent("KTP", "Match ended: $matchid on $map (per-half stats aggregated)", 1);

	return 1;
}

#
# KTP: Handle KTP_HALF_END event
# Sets accurate end_time for the half at the moment gameplay ends (scoreboard appears)
# This fires BEFORE map change/warmup, preventing warmup kills from being attributed to the half
#
sub doEvent_KTPHalfEnd
{
	my ($matchid, $map, $half) = @_;

	return 0 if (!defined($matchid) || $matchid eq "");

	# Get server ID
	my $server_id = $g_servers{$s_addr}->{'id'};

	my $half_num = parseHalfNumber($half);

	&printEvent("KTP_DEBUG", "doEvent_KTPHalfEnd: Setting end_time for half $half_num of match $matchid", 1);

	# Set end_time for this specific half
	# This captures the actual moment gameplay ended, before warmup starts
	&execNonQuery("
		UPDATE ktp_matches
		SET end_time = NOW()
		WHERE match_id = '".quoteSQL($matchid)."'
		AND server_id = $server_id
		AND half = $half_num
		AND end_time IS NULL
	");

	# Clear match context so inter-half kills aren't tagged with match_id
	if (defined($g_ktpMatchContext{$s_addr})) {
		&printEvent("KTP_DEBUG", "doEvent_KTPHalfEnd: Clearing match context for inter-half gap", 1);
		delete $g_ktpMatchContext{$s_addr};
	}

	&printEvent("KTP", "Half ended: $matchid half $half_num on $map (end_time set, context cleared)", 1);

	return 1;
}

sub INT_handler
{
	print "SIGINT received. Flushing data and shutting down...\n";
	flushAll(1);
	exit(0);
}

sub HUP_handler
{
	print "SIGHUP received. Flushing data and reloading configuration...\n";
	&reloadConfiguration;
}
