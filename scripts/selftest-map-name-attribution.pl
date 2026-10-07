#!/usr/bin/perl
# Where a map name is derived, and what hlstats_Maps_Counts is allowed to hold.
#
# Kills keyed to an unusable map name are not lost, they are attributed to
# nothing: every per-map total silently excludes them while the grand total
# still counts them. ON DUPLICATE KEY UPDATE then makes the bad row permanent
# and keeps accreting onto it, so the cheap-looking cleanup (delete the row)
# re-accrues unless the derivation sites refuse the name first.
#
# Three derivation sites and one flush are lifted out of the shipped source and
# run, so a fix that is reverted or paraphrased fails here:
#   - ktpValidMapName          HLstats.plib
#   - doEvent_ChangeMap        HLstats_EventHandlers.plib
#   - ktpParseServerInfo       hlstats.pl   (A2S_INFO reply -> fields)
#   - flushAccumulators        hlstats.pl   (the Maps_Counts write)
#
# Every refusal is also asserted to SAY so. A check that drops a row in silence
# reads exactly like an evening with no kills.
#
#   perl scripts/selftest-map-name-attribution.pl        # exit 0 = pass
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

my %SOURCE = (
    'hlstats.pl'                  => slurp("$DIR/hlstats.pl"),
    'HLstats.plib'                => slurp("$DIR/HLstats.plib"),
    'HLstats_EventHandlers.plib'  => slurp("$DIR/HLstats_EventHandlers.plib"),
);

sub body_of {
    my ($file, $name) = @_;
    my ($body) = ($SOURCE{$file} =~ /\nsub \Q$name\E\s*\{(.*?)\n\}/s);
    die "could not extract sub $name from $file" if (!defined($body));
    return "sub $name {$body\n}\n";
}

# --- collaborators --------------------------------------------------------------
our (%g_roles_accum, %g_weapons_accum, %g_maps_accum, %g_servers, %g_players,
     $s_addr, @sql, @logged);
$s_addr = '127.0.0.1:27015';

sub quoteSQL { my ($v) = @_; $v =~ s/\\/\\\\/g; $v =~ s/'/\\'/g; return $v; }
sub execNonQuery { push(@sql, $_[0]); return 1; }
sub printEvent { push(@logged, join(' ', map { defined($_) ? $_ : '' } @_[0, 1])); return 1; }
sub printNotice { push(@logged, join(' ', map { defined($_) ? $_ : '' } @_)); return 1; }
sub removePlayer { return 1; }
sub endKillStreak { return 1; }

{
    package StubServer;
    sub new { my ($class, %fields) = @_; return bless({ %fields }, $class); }
    sub set { my ($self, $k, $v) = @_; $self->{$k} = $v; return 1; }
    sub increment {
        my ($self, $k, $n) = @_;
        $self->{$k} = ($self->{$k} || 0) + (defined($n) ? $n : 1);
        return 1;
    }
    sub get_map          { return $_[0]->{map}; }
    sub clear_winner     { return 1; }
    sub setHlxCvars      { return 1; }
    sub updateDB         { return 1; }
    sub updatePlayerCount { return 1; }
}

# --- the shipped code under test ------------------------------------------------
my $lifted = body_of('HLstats.plib', 'ktpValidMapName')
    . body_of('HLstats_EventHandlers.plib', 'doEvent_ChangeMap')
    . body_of('hlstats.pl', 'ktpParseServerInfo')
    . body_of('hlstats.pl', 'flushAccumulators');
eval "$lifted\n1;" or die "lifted source did not compile: $@";

# Controls on the lift itself: a slice that stopped matching the shipped shape
# would make every assertion below vacuous.
like($lifted, qr/hlstats_Maps_Counts/,
    'control: the lifted flush is the Maps_Counts writer');
like($lifted, qr/ON DUPLICATE KEY UPDATE/,
    'control: the lifted flush still accretes onto an existing row');
unlike($lifted, qr/selftest_sentinel_not_in_source/,
    'control: a token that is in no source file does not match the lift');

# --- 1. ktpValidMapName ---------------------------------------------------------
for my $good (qw(dod_donner dod_kalt_b4 2fort de_dust2 dod_avalanche.v2 dod-flash)) {
    is(ktpValidMapName($good), $good, "accepts a real map name: $good");
}
is(ktpValidMapName('dod_donner '), 'dod_donner', 'trims a trailing space rather than refusing');

my %bad = (
    'empty string'          => '',
    'undef'                 => undef,
    'whitespace only'       => '   ',
    'a server hostname'     => 'KTP - Atlanta 1',
    'an rcon status tail'   => 'dod_donner at: 0 x',
    'a leading underscore'  => '_donner',
    'a leading dash'        => '-donner',
    'an embedded quote'     => "dod_don'ner",
    'an embedded newline'   => "dod_donner\nmap",
    'over 32 characters'    => 'd' x 33,
    'a bare colon'          => ':',
);
for my $why (sort keys %bad) {
    is(ktpValidMapName($bad{$why}), '', "refuses $why");
}
is(ktpValidMapName('d' x 32), 'd' x 32, 'accepts exactly 32 characters');

# --- 2. doEvent_ChangeMap -------------------------------------------------------
sub change_map {
    my ($type, $name) = @_;
    @logged = ();
    %g_servers = ($s_addr => StubServer->new(id => 42, map => 'dod_previous'));
    doEvent_ChangeMap($type, $name);
    return $g_servers{$s_addr}->{map};
}

is(change_map('started', 'dod_donner'), 'dod_donner',
    'a real map name is stored (so the guard can fail, not only pass)');
is(change_map('loading', 'dod_kalt'), 'dod_kalt', 'the loading branch stores it too');

is(change_map('started', 'KTP - Atlanta 1'), '',
    'an unusable name clears the map instead of being stored');
ok(scalar(grep { /Refused map-change name/ } @logged),
    'and the refusal is logged, not swallowed');

is(change_map('started', undef), '', 'a missing name clears the map');
ok(!scalar(grep { /Refused map-change name/ } @logged),
    'nothing is logged when there was no name to refuse');

# --- 3. ktpParseServerInfo ------------------------------------------------------
# Built byte by byte, not with the shipped unpack template -- a fixture packed
# by the code under test proves only that pack and unpack agree.
my $source_reply = "\xFF\xFF\xFF\xFF" . "I" . chr(48)
    . "KTP - Atlanta 1\0" . "dod_donner\0" . "dod\0" . "Day of Defeat\0"
    . pack("v", 30)
    . chr(2) . chr(32) . chr(0) . chr(100) . chr(108) . chr(0) . chr(1)
    . "1.1.2.7\0" . chr(0) . pack("v", 27015);

my $goldsrc_reply = "\xFF\xFF\xFF\xFF" . "m" . "74.91.121.9:27015\0"
    . "KTP - Atlanta 1\0" . "dod_donner\0" . "dod\0" . "Day of Defeat\0"
    . chr(2) . chr(32) . chr(47) . chr(100) . chr(108) . chr(0) . chr(0);

my $challenge_reply = "\xFF\xFF\xFF\xFF" . "A" . pack("V", 0x5A6B7C8D);

my $info = ktpParseServerInfo($source_reply);
ok(defined($info), 'a Source-format info reply parses');
is($info->{mapname}, 'dod_donner', 'and its map name is the map, not the hostname');
is($info->{hostname}, 'KTP - Atlanta 1', 'and its hostname lands in hostname');
is($info->{maxplayers}, 32, 'and maxplayers survives');

# The pre-fix defect, demonstrated rather than described: the shipped Source
# template read over a GoldSrc reply puts the HOSTNAME in the map field, and a
# `ne ""` caller cannot tell that from a map name.
my %mis = ();
@mis{qw/key type netver hostname mapname gamedir gamename id numplayers maxplayers numbots dedicated os passreq secure gamever edf port/}
    = unpack("LCCZ*Z*Z*Z*vCCCCCCCZ*Cv", $goldsrc_reply);
is($mis{mapname}, 'KTP - Atlanta 1',
    'control: one template over both formats yields a hostname as the map name');
isnt($mis{mapname}, '', 'control: and it is non-empty, so a ne "" guard admits it');

$info = ktpParseServerInfo($goldsrc_reply);
ok(defined($info), 'a GoldSrc-format info reply parses');
is($info->{mapname}, 'dod_donner', 'and its map name is the map, not the hostname');
is($info->{hostname}, 'KTP - Atlanta 1', 'and its hostname lands in hostname');

is(ktpParseServerInfo($challenge_reply), undef, 'a challenge reply is not an info reply');
is(ktpParseServerInfo("\xFF\xFF\xFF\xFFE" . "whatever\0"), undef,
    'an unknown reply type is refused');
is(ktpParseServerInfo("GET / HTTP/1.1\r\n\r\n"), undef,
    'a datagram with no Valve header is refused');
is(ktpParseServerInfo(""), undef, 'an empty datagram is refused');
is(ktpParseServerInfo(undef), undef, 'no datagram is refused');

# --- 4. flushAccumulators: what reaches hlstats_Maps_Counts ---------------------
sub flush_maps {
    my (%accum) = @_;
    @sql = ();
    @logged = ();
    %g_roles_accum = ();
    %g_weapons_accum = ();
    %g_maps_accum = %accum;
    flushAccumulators();
    return grep { /hlstats_Maps_Counts/ } @sql;
}

my @wrote = flush_maps('dod:dod_donner' => { kills => 7, headshots => 2 });
is(scalar(@wrote), 1, 'a real map name still gets its row');
like($wrote[0], qr/VALUES \('dod', 'dod_donner', 7, 2\)/,
    'with its own counts');
is(scalar(%g_maps_accum), 0, 'and the accumulator is drained');

@wrote = flush_maps('dod:' => { kills => 25000, headshots => 900 });
is(scalar(@wrote), 0, 'an empty map name writes no row at all');
ok(scalar(grep { /Withheld 25000 kills from hlstats_Maps_Counts/ } @logged),
    'and the withheld kills are named in the log, so the gap is not silent');

@wrote = flush_maps('dod:KTP - Atlanta 1' => { kills => 3 });
is(scalar(@wrote), 0, 'a junk map name writes no row either');
ok(scalar(grep { /Withheld 3 kills/ } @logged), 'and is reported');

@wrote = flush_maps(
    'dod:dod_donner' => { kills => 4, headshots => 1 },
    'dod:'           => { kills => 6 },
);
is(scalar(@wrote), 1, 'a bad key does not take the good keys down with it');
like($wrote[0], qr/'dod_donner', 4, 1/, 'the good key keeps its own counts');
ok(scalar(grep { /Withheld 6 kills/ } @logged), 'only the bad key is withheld');

@wrote = flush_maps('dod:dod_donner' => { kills => 1 });
ok(!scalar(grep { /Withheld/ } @logged),
    'control: nothing is reported when nothing was withheld');

done_testing();
