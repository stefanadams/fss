#!/usr/bin/perl -w

use strict;
use Term::ReadKey;
use Getopt::Long;
Getopt::Long::Configure ("bundling");
use MIME::Base64;
use Net::LDAP;
use Net::LDAP::Entry;

$|=1;
my $argv = join ' ', @ARGV; $argv =~ s/(\s*-w\s+)\S+(.*?)/$1$2/;

my $e = 0;
my $passwordfile = $ENV{PASSFILE} if defined $ENV{PASSFILE} && -r $ENV{PASSFILE};
my $password = '';
my $help = 0;
my $binddn = "$ENV{LDAPUSER},$ENV{BASEDN}" if defined $ENV{LDAPUSER} && defined $ENV{BASEDN};
my $basedn = "$ENV{BASEDN}" if defined $ENV{BASEDN};
my $original = 0;
my @username = ();
my $m = 'localFollettID';

GetOptions(
	'help|h' => sub { $help = 1 },
	'encoded|e' => sub { $e = 1 },
	'original|o' => \$original,
	'binddn|D=s' => \$binddn,
	'basedn|b=s' => \$basedn,
	'password|w=s' => \$password,
	'passwordfile|W=s' => \$passwordfile,
	'username|u=s' => \@username,
	'm=s' => \$m,
);
$m = $m eq 'uid' ? 'uid' : 'localFollettID';
die <<DIE if $help;
Usage: $0 [OPTIONS]
	-h:	Display this help message and exit
	-e:	Show FingerPrint as encoded Base64
	-o:	Print using original PK
	-D:	Bind DN (Default: $binddn)
	-b:	Base DN (Default: $basedn)
	-w:	LDAP Manager password
	-W:	File containing LDAP Manager password (Default: $passwordfile)
	-u:	Usernames to print FPs for (Default: All)
	-m:	{localFollettID|uid} (Default: localFollettID)
DIE

if ( $passwordfile && -f $passwordfile && -r _ ) {
	chomp($password = qx{cat $passwordfile});
} elsif ( !$password ) {
	print "Enter LDAP Password: ";
	ReadMode 'noecho';
	chomp($password = ReadLine);
	ReadMode 'normal';
}
my $ldap = Net::LDAP->new('ldap.example.com', version => 3);
my $bind = $ldap->bind($binddn, password=>$password);
if ( $bind->code ) {
	die "Invalid DN and/or password: $binddn\n";
}
undef $password; undef $passwordfile;

my $search;

my $F = $#username < 0 ? 'localFSSpk=*' : '(&(localFSSpk=*)(|(uid='.(join ')(uid=', @username).')(localFSSpk='.(join ')(localFSSpk=', @username).')))';
$search = $ldap->search(
	base=>"$basedn",
	filter => "$F",
	attrs => ['localFSSpk',$m],
);
$search->code && die $search->error;
for ( 0..$search->count ) {
	if ( my $entry = $search->entry($_) ) {
		my $dn = $entry->dn();
		my $pk = $entry->get_value('localFSSpk');
		my $pin = $entry->get_value($m);
		if ( $pk && $pin ) {
			$pk = $e ? $pk : decode_base64($pk);
			unless ( $e ) {
				my ($uid) = ($pk =~ /^(\w+)/);
				my $uidl = length($uid);
				my $pinl = length($pin);
				my $filler = $uidl-$pinl > 0 ? "\000" x ($uidl-$pinl) : '';
				my $unfiller = $pinl-$uidl > 0 ? $pinl-$uidl : 0;
				$pk =~ s/^.{$uidl}.{$unfiller}/$pin$filler/ unless $original;
			}
			print $pk;
		}
	}
}
