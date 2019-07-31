#!/usr/bin/perl -w
# env BASEDN="o=local" LDAPUSER="cn=Manager" PASSFILE=/tmp/ldap.secret ./fss.pl -e

use strict;
use Text::Wrap qw(wrap $columns $huge);
use Term::ReadKey;
use Term::ANSIColor qw(:constants);
$Term::ANSIColor::AUTORESET = 1;
use Getopt::Long;
Getopt::Long::Configure ("bundling");
use Sys::Syslog;
use Date::Manip;
use MIME::Base64;
use Net::MAC;
use Net::LDAP;
use Net::LDAP::Entry;
use File::Basename;
use MIME::Base64;
use Lingua::EN::NameCase;
use Lingua::EN::NameParse;
use Lingua::EN::MatchNames;
use Tk;
use Tk::Pane;

$|=1;
$ENV{syslog} = 'info|local6';
# Configure syslog and logrotate:
#   /etc/syslog.conf:
#     local6.*                                                -/var/log/fss.log
#   /etc/logrotate.d/syslog:
#     /var/log/fss.log {\nsharedscripts\nrotate 5\nweekly\npostrotate\n/usr/bin/killall -HUP syslogd #\nendscript\n}
openlog(basename($0), 'ndelay', 'local6');
my $argv = join ' ', @ARGV; $argv =~ s/(\s*-w\s+)\S+(.*?)/$1$2/;
message(0, "Start options: $argv");
$SIG{'INT'} = sub { ReadMode 'normal'; message(2, 'Control-C interrupt exit.', 'Reload'); exit 0; };

my $progpath = dirname $0;
my $config = "$progpath/fss.conf";
$config = '/etc/fss.conf' unless -f $config && -r _;
$config = '' unless -f $config && -r _;
my $echo = 0;
my $pictures = 0;
my $picturedir = '/data/vhosts/webspeedpics.example.com/htdocs/skywardpictures';
my $pictureurl = 'http://webspeedpics.example.com/skywardpictures';
my $passwordfile = $ENV{PASSFILE} if defined $ENV{PASSFILE} && -r $ENV{PASSFILE};
my $password = '';
my $auth = 0;
my $autocheckin = 0;
my $showauth = 0;
my $behalf = 1;
my $help = 0;
my $binddn = "$ENV{LDAPUSER},$ENV{BASEDN}";
my $multiple = 0;
my $gui = 0;

GetOptions(
	'help|h' => sub { $help = 1 },
	'config|c' => sub { $config = 1 },
	'echo|e' => sub { $echo = 1 },
	'multiple|m' => sub { $multiple = 1 },
	'auth|a' => sub { $auth = 1 },
	'autocheckin|C' => sub { $autocheckin = 1 },
	'showauth|A' => sub { $showauth = 1 },
	'behalf|b' => sub { $behalf = 0 },
	'pictures|p' => sub { $pictures = 1 },
	'picturedir|P=s' => \$picturedir,
	'pictureurl|U=s' => \$pictureurl,
	'binddn|D=s' => \$binddn,
	'password|w=s' => \$password,
	'passwordfile|W=s' => \$passwordfile,
	'gui|G' => \$gui,
);
die <<DIE if $help;
Usage: $0 [OPTIONS]
	-h:	Display this help message and exit
	-c:	FSS Config file (Default: $config)
	-e:	Display keyboard input (Default: hide)
	-m:	Allow multiple rentals (Default: disallow)
	-a:	Require transaction authorization (Default: skip)
	-C:	Allow auto-checkin (Default: disallow)
	-A:	Show authorized transactors and exit
	-b:	Do not allow returns on behalf of another (Default: allow)
	-p:	Display URL to user's picture (Default: skip)
	-P:	Linux path to pictures (Default: $picturedir)
	-U:	Base URL to pictures (Default: $pictureurl)
	-D:	Bind DN (Default: $binddn)
	-w:	LDAP Manager password
	-W:	File containing LDAP Manager password (Default: $passwordfile)
	-G:	Run with a GUI (Default: $gui)
DIE
$ENV{echo} = $echo == 1 ? 'normal' : 'noecho';	# If barcode/bio problems, run in echo mode and the admin can key the data in using the keyboard
$ENV{behalf} = $behalf;
$ENV{multiple} = $multiple;

my @authorized = authorized($config);
message(1, @authorized) if $showauth;

my ($authorizer, $localDevice, $bio);
my %authorizer = ();
my %localDevice = ();
my %bio = ();

my $name = new Lingua::EN::NameParse(auto_clean=>1, force_case=>1, lc_prefix=>1, initials=>1, allow_reversed=>1, joint_names=>0, extended_titles=>0);
my $ldap = Net::LDAP->new('ldap.example.com', version => 3);
my $bind = $ldap->bind($binddn, password=>bindpw($password, $passwordfile));
message($bind->code ? (2, "Invalid DN and/or password: $binddn") : (0, "Successful bind: $binddn"));
undef $password; undef $passwordfile;

#my $mw = tkinit;
my $mw = MainWindow->new();
$mw->protocol('WM_DELETE_WINDOW', sub { exit; });
$mw->bind("<Alt-F4>", sub { exit; });
$mw->optionAdd('*font', 'Helvetica 12');
$mw->title('Laptop Checkout');
$mw->geometry('800x600+1+1');
$mw->resizable(0,0);

my $f = $mw->Frame(-bg=>'black')->pack(-side=>'top',-fill=>'x');
my $p = $f->Scrolled('Pane', -scrollbars => 'osoe', -height=>600, -width=>800,)->pack;
$p->Label(-text => "", -justify=>'left')->pack(-side=>'top',-fill=>'x');
p(<<WELCOME);
This program expects pairs of information.  One part is a human fingerprint
while the other is a computer serial number.  It does not matter in which order
the data is entered; however, when a pair is received, the order is immediately
logged and processed.
An audible "beep" means that the person's fingerprint was not read properly or
the person has not been enrolled in the system.
WELCOME
p("Testing color...\n");
p("OK\n");
p(<<ECHO) if $ENV{echo} eq 'normal';
Running in keyboard entry mode!
To enter a fingerprint: FSSusernameFSS
To enter a device: just:type:in:the:serial:number
To see status info of current input: <Enter>
ECHO
p("\n");
report();
reader(input($bio, $localDevice));
MainLoop;
closelog();

my $lastinput = '';
sub reader {
	# Still waiting for a matching pair
	if ( !($bio && $localDevice) ) {
		# No input, i.e. press Enter
		# Show status
		if ( /^\s*$/ || /^0+$/ || /^(S0+\d+)$/ || /^(QUERY\d+)$/ ) {
			if ( $bio ) {
				report(bio=>$bio);
			} elsif ( $localDevice ) {
				report(localDevice=>$localDevice);
			} elsif ( $1 ) {
				report(special=>$1);
			} else {
				report();
			}
			$lastinput = '';
			clearinput(qw{authorizer bio localDevice});
		# Exit the fss.sh while loop.
		# Complete exit.
		} elsif ( /^1+$/ ) {
			message(2, "Exit.");
			exit 1;
		# Clear auditing attributes for $localDevice
		} elsif ( /^D{10,}$/i ) {
			message(2, "Reset auditing:");
			resetdevice($localDevice);
			$lastinput = '';
			clearinput(qw{localDevice});
		# Clear Screen
		} elsif ( /^L{1,}$/i ) {
			print "\n" x 30;
		# Add device
		} elsif ( /^\+$/ ) {
		# Modify device
		} elsif ( /^\-$/ ) {
		# Bio input
		} elsif ( /^FSS(.*?)FSS$/ ) {
			# Discard duplicate entries
			next if $_ eq $lastinput; $lastinput = $_;
			$bio = $1;
			message(0, "Got FSS Biometric input: $bio");
			$ENV{LDAPOPERATION} = '&';
			%bio = getbio($bio);
			delete $ENV{LDAPOPERATION};
			if ( scalar keys %bio == 0 ) {
				message(2, "uid=$bio not found in LDAP!", "Person not found in LDAP!  Do not allow person to check-out any devices until this problem has been resolved.");
				$lastinput = '';
				clearinput(qw{bio});
			} elsif ( scalar keys %bio == 1 ) {
				%bio = %{$bio{0}};
				message(2, "$bio{description}: $bio{gecos}");
				print "  $pictureurl/$bio{'skyward-STUDENT-ID'}.JPG\n" if $pictures && -f "$picturedir/$bio{'skyward-STUDENT-ID'}.JPG";
			} elsif ( scalar keys %bio > 1 ) {
				message(2, "Multiple entries for uid=$bio found in LDAP!", "Multiple entries for person found in LDAP!  Do not allow person to check-out any devices until this problem has been resolved.");
				$lastinput = '';
				clearinput(qw{bio});
			} else {
				message(1, "ERROR");
			}
		# Anything else is expected to be a device
		} else {
			# Discard duplicate entries
			next if $_ eq $lastinput; $lastinput = $_;
			chomp($localDevice=$_);
			my $mac = eval {
				my $mac = Net::MAC->new(mac => $localDevice);
				$mac = $mac->convert(delimiter => ':');
				$mac->get_mac();
			} || $localDevice;
			message(0, "Got other input: $localDevice");
			$ENV{LDAPOPERATION} = '|';
			%localDevice = getdevice(localDeviceName=>$localDevice, localDeviceLANMAC=>$mac, localDeviceWLANMAC=>$mac, localDeviceSerialNumber=>$localDevice, localDeviceLocalSerialNumber=>$localDevice);
			delete $ENV{LDAPOPERATION};
			if ( scalar keys %localDevice == 0 ) {
				message(2, "$localDevice not found in LDAP!", "Device not found in LDAP!  Do not allow anyone to check-out this device until this problem has been resolved.");
				$lastinput = '';
				clearinput(qw{localDevice});
			} elsif ( scalar keys %localDevice == 1 ) {
				%localDevice = %{$localDevice{0}};
				message(2, "$localDevice{Type}: $localDevice{Name}");
				if ( $autocheckin && !$bio ) {
					if ( ($localDevice{CheckInTimeStamp} && $localDevice{CheckOutTimeStamp} && Date_Cmp($localDevice{CheckInTimeStamp}, $localDevice{CheckOutTimeStamp}) < 0 ) || ( !$localDevice{CheckInTimeStamp} && $localDevice{CheckOutTimeStamp} ) ) {
						$ENV{LDAPOPERATION} = '&';
						%bio = getbio('fss');
						%bio = %{$bio{0}};
						delete $ENV{LDAPOPERATION};
						checkin(\%bio, \%localDevice);
						$lastinput = '';
						clearinput(qw{localDevice});
					}
				}
			} elsif ( scalar keys %localDevice > 1 ) {
				message(2, "Multiple entries for device=$localDevice found in LDAP!", "Multiple entries for device found in LDAP!  Do not allow person to check-out any devices until this problem has been resolved.");
				$lastinput = '';
				clearinput(qw{localDevice});
			} else {
				message(1, "ERROR");
			}
		}
	}

	next unless $bio && $localDevice;
	#$lastinput = '';

	# Got a pair, get authorization
	if ( $auth ) {
		p("Please have an authorized person verify this transaction with a fingerprint:\n");
		$_ = input();
		# Bio input
		if ( /^FSS(.*?)FSS$/ ) {
			$authorizer = $1;
			message(0, "Got FSS Biometric input for authorizer: $authorizer");
			if ( grep { /^$authorizer$/ } @authorized ) {
				$ENV{LDAPOPERATION} = '&';
				%authorizer = getbio($authorizer);
				delete $ENV{LDAPOPERATION};
				if ( scalar keys %authorizer == 0 ) {
					message(2, "$authorizer not found in LDAP!", "Authorizer not found in LDAP!  Do not allow person to check-out any devices until this problem has been resolved.");
					clearinput(qw{authorizer bio localDevice});
				} elsif ( scalar keys %authorizer == 1 ) {
					%authorizer = %{$authorizer{0}};
					my $authorizedby = expanduid($authorizer{uid});
					message(2, "Transaction authorized by $authorizedby.");
				} elsif ( scalar keys %authorizer > 1 ) {
					message(2, "Multiple entries for authorizer=$authorizer found in LDAP!", "Multiple entries for authorizer found in LDAP!  Do not allow person to check-out any devices until this problem has been resolved.");
					clearinput(qw{authorizer bio localDevice});
				} else {
					message(1, "ERROR");
				}
			} else {
				message(2, "$authorizer not authorized", "You are not authorized to authorize this transaction.  Do not allow person to check-out any devices until this problem has been resolved.");
				clearinput(qw{authorizer bio localDevice});
			}
		# Anything else is not accepted
		} else {
			message(2, "Invalid authorization biometric input", "This is not a valid biometric input.  Do not allow person to check-out any devices until this problem has been resolved.");
			clearinput(qw{authorizer bio localDevice});
		}
	}

	# Here it is!  Check it in or out.
	if ( !$auth || $authorizer ) {
		if ( $localDevice{CheckInTimeStamp} && $localDevice{CheckOutTimeStamp} ) {
			if ( Date_Cmp($localDevice{CheckInTimeStamp}, $localDevice{CheckOutTimeStamp}) > 0 ) {
				checkout(\%bio, \%localDevice);
			} elsif ( Date_Cmp($localDevice{CheckInTimeStamp}, $localDevice{CheckOutTimeStamp}) < 0 ) {
				checkin(\%bio, \%localDevice);
			} else {
				message(2, "Too fast!!  Try again!");
			}
		} elsif ( $localDevice{CheckInTimeStamp} && !$localDevice{CheckOutTimeStamp} ) {
			checkout(\%bio, \%localDevice);
		} elsif ( !$localDevice{CheckInTimeStamp} && $localDevice{CheckOutTimeStamp} ) {
			checkin(\%bio, \%localDevice);
		} else {
			checkout(\%bio, \%localDevice);
		}
		clearinput(qw{authorizer bio localDevice});
	}
	$mw->after(1000, \&reader);
}

# -----------------------------------------------------------------------

sub clearinput {
	foreach ( @_ ) {
		if ( /^authorizer$/ ) { $authorizer = ''; %authorizer = (); }
		if ( /^bio$/ ) { $bio = ''; %bio = (); }
		if ( /^localDevice$/ ) { $localDevice = ''; %localDevice = (); }
	}
}

sub report {
	my (%report) = @_;
	if ( $report{localDevice} ) {
		message(2, "Device Report: $localDevice{Name}");
		if ( $localDevice{CurrentUser} ) {
			my $currentuser = expanduid($localDevice{CurrentUser});
			my $howlong = howlong($localDevice{CheckOutTimeStamp}, 'now');
			my $checkedout = UnixDate(ParseDate($localDevice{CheckOutTimeStamp}), '%l');
			p("$localDevice{Name} is currently checked-out by $currentuser.  It has been checked-out for $howlong since $checkedout.\n");
		} else {
			p("$localDevice{Name} is not currently checked-out by anyone.\n");
			if ( $localDevice{CheckOutTimeStamp} && $localDevice{CheckInTimeStamp} ) {
				my $lastuser = expanduid($localDevice{LastUser}) || 'no one';
				my $checkedout = UnixDate(ParseDate($localDevice{CheckOutTimeStamp}), '%l') || 'an unknown date';
				my $howlong = howlong($localDevice{CheckOutTimeStamp}, $localDevice{CheckInTimeStamp});
				my $returnedby = expanduid($localDevice{ReturnedBy}) || $lastuser;
				p("$localDevice{Name} was last checked-out by $lastuser on $checkedout for $howlong and returned by $returnedby.\n");
			} else {
				p("$localDevice{Name} has not yet been checked-out by anyone.\n");
			}
		}
	} elsif ( $report{bio} ) {
		my $person = expanduid($bio{uid}) || $bio{uid};
		message(2, "Bio Report: $bio{gecos}");
		my %localDeviceCU = getdevice(localDeviceCurrentUser=>$bio{uid});
		if ( scalar keys %localDeviceCU == 0 ) {
			p("$person currently does not have anything checked-out.\n");
		} elsif ( scalar keys %localDeviceCU >= 1 ) {
			for ( 0..(scalar keys %localDeviceCU) - 1) {
				%_ = %{$localDeviceCU{$_}};
				my $howlong = howlong($_{CheckOutTimeStamp}, 'now');
				my $checkedout = UnixDate(ParseDate($_{CheckOutTimeStamp}), '%l');
				p("$person currently has $_{Name} checked-out which has been checked-out for $howlong since $checkedout.\n");
			}
		}
		my %localDevicelu = getdevice(localDeviceLastUser=>$bio{uid});
		if ( scalar keys %localDevicelu == 0 ) {
			p("$person has not had anything else checked-out.\n");
		} elsif ( scalar keys %localDevicelu >= 1 ) {
			for ( 0..(scalar keys %localDevicelu) - 1) {
				%_ = %{$localDevicelu{$_}};
				my $howlong = howlong($_{CheckOutTimeStamp}, $_{CheckInTimeStamp});
				my $checkedout = UnixDate(ParseDate($_{CheckOutTimeStamp}), '%l');
				my $returnedby = expanduid($_{ReturnedBy}) || $person;
				p("$_{Name} was last checked-out by $person on $checkedout for $howlong and it was returned by $returnedby.\n");
			}
		}
	} elsif ( $report{special} ) {
		if ( $report{special} =~ /^QUERY001$/ ) {
			p("A listing of computers currently checked out for more than 90 minutes and by whom\n");
			my $type = 'Laptop';
			my %localDeviceCO = getdevice(localDeviceType=>$type, localDeviceDescription=>"checkout");
			%_ = ();
			foreach ( keys %localDeviceCO ) {
				next unless $localDeviceCO{$_}{CurrentUser};
				my $err;
			        my ($y, $m, $k, $d, $H, $M, $S) = split /:/, DateCalc($localDeviceCO{$_}{CheckOutTimeStamp}, 'now', \$err, 1);
				my $secs = ($H*60*60)+($M*60)+($S);
				$_{$_} = $localDeviceCO{$_} if $secs >= ((1*60*60)+(30*60)+(0*60));
			}
			%localDeviceCO = %_;
			my $localDeviceCO = scalar keys %localDeviceCO;
			my $list = join '; ', map { "$localDeviceCO{$_}{Name}: ".expanduid($localDeviceCO{$_}{CurrentUser}) } keys %localDeviceCO;
			p("There ${\($localDeviceCO == 1 ? 'is' : 'are')} currently $localDeviceCO Cart ${\($localDeviceCO == 1 ? 'tablet' : 'tablets')} that have been checked-out for more than 90 minutes:\n$list\n");
		} elsif ( $report{special} =~ /^QUERY002$/ ) {
			p("A listing of computers currently checked out and by whom\n");
			my $type = 'Laptop';
			my %localDeviceCO = getdevice(localDeviceType=>$type, localDeviceDescription=>"checkout");
			%_ = ();
			foreach ( keys %localDeviceCO ) {
				next unless $localDeviceCO{$_}{CurrentUser};
				my $err;
				$_{$_} = $localDeviceCO{$_};
			}
			%localDeviceCO = %_;
			my $localDeviceCO = scalar keys %localDeviceCO;
			my $list = join '; ', map { "$localDeviceCO{$_}{Name}: ".expanduid($localDeviceCO{$_}{CurrentUser}) } keys %localDeviceCO;
			p("There ${\($localDeviceCO == 1 ? 'is' : 'are')} currently $localDeviceCO Cart ${\($localDeviceCO == 1 ? 'tablet' : 'tablets')} that have been checked-out:\n$list\n");
		} elsif ( $report{special} =~ /^QUERY003$/ ) {
			p("A listing of computers currently registered\n");
			my $type = 'Laptop';
			my %localDeviceCO = getdevice(localDeviceType=>$type, localDeviceDescription=>"checkout");
			my $localDeviceCO = scalar keys %localDeviceCO;
			my $list = join '; ', sort map { $localDeviceCO{$_}{Name} } keys %localDeviceCO;
			p("There ${\($localDeviceCO == 1 ? 'is' : 'are')} currently $localDeviceCO Cart ${\($localDeviceCO == 1 ? 'tablet' : 'tablets')} registered:\n$list\n");
		} elsif ( $report{special} =~ /^QUERY004$/ ) {
			p("Enter Name: ");
			if ( my @ul = Ul(input('normal')) ) {
				p("Best guess: ".join(', ', @ul)."\n");
			} else {
				p("No matches.\n");
			}
		} elsif ( $report{special} =~ /^QUERY005$/ ) {
			p("Username: ");
			p(pl(input('normal'))."\n");
		} elsif ( $report{special} =~ /^QUERY101$/ ) {
			p("A complete listing of the tablet computers registered in the system\n");
		} elsif ( $report{special} =~ /^QUERY102$/ ) {
			p("A listing of computers currently checked out and by whom\n");
		} else {
			p("This report has not yet been defined.\n")
		}
	} else {
		message(2, "Complete Report:");
		# How many tablets are there total?
		{
			my $type = 'Laptop';
			my %localDeviceCO = getdevice(localDeviceType=>$type, localDeviceDescription=>"checkout");
			my $localDeviceCO = scalar keys %localDeviceCO;
			p("There ${\($localDeviceCO == 1 ? 'is' : 'are')} a total of $localDeviceCO Cart ${\($localDeviceCO == 1 ? 'tablet' : 'tablets')}.\n");
		}
		# How many tablets are currently checked-out?
		{
			my $type = 'Laptop';
			my %localDeviceCO = getdevice(localDeviceType=>$type, localDeviceDescription=>"checkout", localDeviceCurrentUser=>'*');
			my $localDeviceCO = scalar keys %localDeviceCO;
			local %_ = ();
			my $peopleco = scalar grep { !$_{$_}++ } map { $localDeviceCO{$_}{CurrentUser} } keys %localDeviceCO;
			p("There ${\($localDeviceCO == 1 ? 'is' : 'are')} currently $localDeviceCO Cart ${\($localDeviceCO == 1 ? 'tablet' : 'tablets')} checked-out by $peopleco ${\($peopleco == 1 ? 'person' : 'people')}.\n");
		}
		# How many tablets are available?
		{
			my $type = 'Laptop';
			my %localDeviceCO = getdevice(localDeviceType=>$type, localDeviceDescription=>"checkout", localDeviceCurrentUser=>'!*');
			my $localDeviceCO = scalar keys %localDeviceCO;
			p("There ${\($localDeviceCO == 1 ? 'is' : 'are')} currently $localDeviceCO Cart ${\($localDeviceCO == 1 ? 'tablet' : 'tablets')} available for check-out.\n");
		}
		# How many have been out for more than 1 week?
		{
			my $type = 'Laptop';
			my %localDeviceCO = getdevice(localDeviceType=>$type, localDeviceDescription=>"checkout");
			%_ = ();
			foreach ( keys %localDeviceCO ) {
				next unless $localDeviceCO{$_}{CurrentUser};
				my $err;
			        my ($y, $m, $k, $d, $H, $M, $S) = split /:/, DateCalc($localDeviceCO{$_}{CheckOutTimeStamp}, 'now', \$err, 1);
				$_{$_} = $localDeviceCO{$_} if $k >= 1;
			}
			%localDeviceCO = %_;
			my $localDeviceCO = scalar keys %localDeviceCO;
			my $list = join '; ', map { "$localDeviceCO{$_}{Name}: ".expanduid($localDeviceCO{$_}{CurrentUser}) } keys %localDeviceCO;
			p("There ${\($localDeviceCO == 1 ? 'is' : 'are')} currently $localDeviceCO Cart ${\($localDeviceCO == 1 ? 'tablet' : 'tablets')} that have been checked-out for more than one week: $list\n");
		}
		# Which is out for the longest and how long and by whom?
		{
			my $type = 'Laptop';
			my %localDeviceCO = getdevice(localDeviceType=>$type, localDeviceDescription=>"checkout");
			my $longest = -1;
			my $longests = -1;
			foreach ( keys %localDeviceCO ) {
				next unless $localDeviceCO{$_}{CurrentUser};
			        my $a = UnixDate(ParseDate($localDeviceCO{$_}{CheckOutTimeStamp}), "%o");
				my $b = UnixDate(ParseDate('now'), "%o");
				my $secs = $b - $a;
				do { $longest = $_; $longests = $secs } if $secs > $longests;
			}
			if ( $longest >= 0 ) {
				%localDeviceCO = %{$localDeviceCO{$longest}};
				my $currentuser = expanduid($localDeviceCO{CurrentUser}) || 'no one';
				my $checkedout = UnixDate(ParseDate($localDeviceCO{CheckOutTimeStamp}), '%l');
				my $howlong = howlong($localDeviceCO{CheckOutTimeStamp}, 'now');
				p("$localDeviceCO{Name} has been checked-out for the longest amount of time by $currentuser on $checkedout for $howlong.\n");
			} else {
				p("No devices are currently checked-out by anyone.\n");
			}
		}
		#   localDeviceLocation=Unknown
		#   $_{DateCalc(Out, now)}=name
		#   sort %_
	}
}

sub input {
	my $bio = shift;
	my $localDevice = shift;
	p("\n") if !$bio && !$localDevice;
	my $echo = defined $_[0] ? $_[0] : $ENV{echo};
	ReadMode $echo;
	do { $_ = ReadLine } until defined $_;
	message(0, "STDIN: $_");
	ReadMode 'normal';
	return $_;
}

sub message {
	my ($type, $message1, $message2) = @_;
	$message2 = $message1 unless $message2;
	syslog($ENV{syslog}, $message1);
	if ( $type == 0 ) {
	} elsif ( $type == 1 ) {
		die "$message2\n";
	} elsif ( $type >= 2 ) {
		p("$message2\n");
	}
}

sub p {
	$columns = 80;
	my $initial_tab = "";
        my $subsequent_tab = "";
	$p->Label(-text => wrap($initial_tab, $subsequent_tab, @_), -justify=>'left')->pack(-side=>'top',-fill=>'x');
}

sub bindpw {
	my ($password, $passwordfile) = @_;
	# use Term::ReadKey;
	if ( $passwordfile && -f $passwordfile && -r _ ) {
		chomp($password = qx{cat $passwordfile});
	} elsif ( !$password ) {
		print "Enter LDAP Password: ";
		ReadMode 'noecho';
		do { chomp($password = ReadLine) } until defined $password;
		ReadMode 'normal';
	}
	return $password;
}

sub Ul {
	return unless / /;
	$name->parse(@_);
	my %names = ();
	my %name = $name->case_components;
	my $search = $ldap->search(
		base=>"ou=People,$ENV{BASEDN}",
		filter => "sn=$name{surname_1}",
	);
	for ( 0..($search->count - 1) ) {
		no warnings;
		my $entry = $search->entry($_);
		next unless $name{given_name_1} && $name{surname_1} && $entry->get_value('givenName') && $entry->get_value('sn');
		my $score = 0;
		eval {
			no warnings;
			$score = name_eq($name{given_name_1}, $name{surname_1}, $entry->get_value('givenName'), $entry->get_value('sn')) || 0;
		};
		$names{$score}{$entry->get_value('uid')} = $entry->get_value('gecos');
	}
	return unless keys %names >= 1;
	my @rank = sort { $b <=> $a } keys %names;
	return keys %{$names{$rank[0]}};
}

sub Ulreport {
	my $cols = shift;
	my $rand = rand();
	$rand =~ s/^\d+\.//;
	local $~ = "LIST$rand";
	my $format  = "format LIST$rand = \n"
		. '@>>> | @' . '<' x $cols . ' | @'. '<' x (65-$cols) . "\n"
		. '@_' . "\n"
		. ".\n";
	eval $format;
	die $@ if $@;
	write();
}

sub pl {
	chomp($_[0]);
	return "No username entered.\n" unless $_[0];
	my $search = $ldap->search(
		base=>"ou=People,$ENV{BASEDN}",
		filter => "uid=$_[0]",
	);
	return "Username not found.\n" unless $search->count == 1;
	my $entry = $search->entry(0);
	return $entry->get_value('userPassword');
}

sub getldap {
	my $base = shift @_;
	my %filter = ();
	if ( $#_ < 0 ) {
		%filter = ( uid => '*' );
	} elsif ( $#_ == 0 ) {
		%filter = ( uid => $_[0] );
	} elsif ( $#_ > 0 ) {
		%filter = @_;
	}
	$ENV{LDAPOPERATION} ||= '&';
	my $filter = "($ENV{LDAPOPERATION}".join('', map { $filter{$_} =~ s/^\!// ? "(!($_=$filter{$_}))" : "($_=$filter{$_})" } keys %filter).')';
	delete $ENV{LDAPOPERATION};
	my $search = $ldap->search(
		base=>"ou=$base,$ENV{BASEDN}",
		filter => "$filter",
	);
#print "\n\n$filter\n\n";
	if ( $search->code ) {
		message(1, $search->error);
	}
	my %ldap = ();
	return %ldap if $search->count == 0;
	for my $i ( 0..$search->count ) {
		if ( my $entry = $search->entry($i) ) {
			$ldap{$i}{dn} = $entry->dn();
			foreach ( $entry->attributes ) {
				$ldap{$i}{$_} = $entry->get_value($_);
				if ( s/^localDevice// ) {
					$ldap{$i}{$_} = $entry->get_value("localDevice$_");
				} else {
					$ldap{$i}{$_} = $entry->get_value($_);
				}
			}
		} else {
			delete $ldap{$i};
		}
	}
	return %ldap;
}

sub getbio {
	return getldap('People', @_);
}

sub getdevice {
	return getldap('Devices', @_);
}

sub authorized {
	my ($config) = @_;
	return undef unless $config;
	my @config = ();
	return undef unless open CONFIG, $config;
	@config = <CONFIG>;
	close CONFIG;
	my @authorized = map { /^authorized\s*=\s*(.*)/; split /\s+/, $1 } grep { /^authorized\s*=\s*/ } @config;
	my @authgroup = map { /^authgroup\s*=\s*(.*)/; split /\s+/, $1 } grep { /^authgroup\s*=\s*/ } @config;
	foreach ( @authgroup ) {
		push @authorized, (split /\s+/, (getgrnam($_))[3]);
	}
	%_ = ();
	foreach ( @authorized ) {
		$_{$_}++;
	}
	return sort keys %_;
}

sub howlong {
	my $err;
	my ($y, $m, $k, $d, $H, $M, $S) = split /:/, DateCalc(ParseDate($_[0]), ParseDate($_[1]), \$err, 1);
	$y =~ s/^[+-]//;
	my @howlong = ();
	push @howlong, "$y year".($y>1?'s':'') if $y;
	push @howlong, "$m month".($m>1?'s':'') if $m;
	push @howlong, "$k week".($k>1?'s':'') if $k;
	push @howlong, "$d day".($d>1?'s':'') if $d;
	push @howlong, "$H hour".($H>1?'s':'') if $H;
	push @howlong, "$M minute".($M>1?'s':'') if $M;
	return $#howlong>=0 ? join ' ', @howlong : 'less than one minute';
}

sub expanduid {
	my ($bio) = @_;
	return undef unless $bio;
	my %bio = getbio($bio);
	if ( scalar keys %bio == 0 ) {
		message(2, "Person ($bio) not found in LDAP!");
		return undef;
	} elsif ( scalar keys %bio == 1 ) {
		%bio = %{$bio{0}};
		my $yr = (localtime())[5];
		$yr += 1900;
		$yr++ if (localtime())[4] >= 7;
		return $bio{gecos} unless $bio{'localStudentGradYr'};
		if ( $bio{'localStudentGradYr'} < $yr ) {
			return "$bio{gecos} (Graduated)";
		} elsif ( $bio{'localStudentGradYr'} == $yr ) {
			return "$bio{gecos} (Senior)";
		} elsif ( $bio{'localStudentGradYr'} == $yr + 1 ) {
			return "$bio{gecos} (Junior)";
		} elsif ( $bio{'localStudentGradYr'} == $yr + 2 ) {
			return "$bio{gecos} (Sophomore)";
		} elsif ( $bio{'localStudentGradYr'} == $yr + 3 ) {
			return "$bio{gecos} (Freshman)";
		} elsif ( $bio{'localStudentGradYr'} >= $yr + 4 ) {
			return "$bio{gecos} (Elementary)";
		}
	} else {
		message(2, "Multiple entries for person ($bio) found in LDAP!");
		return undef;
	}
}

sub resetdevice {
	my ($localDevice) = @_;
	$localDevice ||= '*';
	$ENV{LDAPOPERATION} = '|';
	my %localDeviceQ = getdevice(localDeviceName=>$localDevice, localDeviceLANMAC=>$localDevice, localDeviceWLANMAC=>$localDevice, localDeviceSerialNumber=>$localDevice, localDeviceLocalSerialNumber=>$localDevice);
	delete $ENV{LDAPOPERATION};
	for ( 0..(scalar keys %localDeviceQ) - 1 ) {
		next unless $localDeviceQ{$_}{dn};
		next unless $localDeviceQ{$_}{Location} && $localDeviceQ{$_}{Location} eq 'Unknown';
		next unless $localDeviceQ{$_}{Type} && $localDeviceQ{$_}{Type} =~ /^Laptop$|^Tablet$/;
		next unless $localDeviceQ{$_}{CurrentUser} || $localDeviceQ{$_}{LastUser} || $localDeviceQ{$_}{ReturnedBy} || $localDeviceQ{$_}{CheckInTimeStamp} || $localDeviceQ{$_}{CheckOutTimeStamp};
		my $entry = Net::LDAP::Entry->new;
		$entry->dn($localDeviceQ{$_}{dn});
		$entry->changetype('modify');
		$entry->delete('localDeviceCurrentUser') if $localDeviceQ{$_}{CurrentUser};
		$entry->delete('localDeviceLastUser') if $localDeviceQ{$_}{LastUser};
		$entry->delete('localDeviceReturnedBy') if $localDeviceQ{$_}{ReturnedBy};
		$entry->delete('localDeviceCheckInTimeStamp') if $localDeviceQ{$_}{CheckInTimeStamp};
		$entry->delete('localDeviceCheckOutTimeStamp') if $localDeviceQ{$_}{CheckOutTimeStamp};
		my $update = $entry->update($ldap);
		if ( $update->code ) {
			print "!!! FATAL ERROR (resetdevice)\n";
			message(1, $update->error);
		}
		message(2, "Reset: $localDeviceQ{$_}{Name}");
	}
}

sub checkout {
	my ($bio, $localDevice) = @_;
	my %bio = %{$bio};
	my %localDevice = %{$localDevice};
	my $search = $ldap->search(
		base=>"ou=Devices,$ENV{BASEDN}",
		filter => "localDeviceCurrentUser=$bio{uid}",
	);
	if ( $search->entry(0) && !$ENV{multiple} ) {
		my $entry = $search->entry(0);
		message(2, "$bio{gecos} still has ".$entry->get_value('localDeviceName')." checked-out and is not allowed any more!");
		print BOLD RED "!!! Do NOT give anything to $bio{gecos}!\n";
		return undef;
	} else {
		$localDevice{CheckOutTimeStamp} = ParseDate('now');
		$localDevice{CurrentUser} = $bio{uid};
		my $entry = Net::LDAP::Entry->new;
		$entry->dn($localDevice{dn});
		$entry->changetype('modify');
		$entry->delete('localDeviceReturnedBy') if $localDevice{ReturnedBy};
		$entry->replace(
			localDeviceCurrentUser => $localDevice{CurrentUser},
			localDeviceCheckOutTimeStamp => $localDevice{CheckOutTimeStamp},
		);
		my $update = $entry->update($ldap);
		if ( $update->code ) {
			print BOLD RED "!!! FATAL ERROR (checkout): DO NOT GIVE ANYTHING TO ANYONE.  Suspend all further transactions until error is resolved.\n";
			message(1, $update->error);
		}
		message(2, "$localDevice{Name} checked out by $bio{gecos} at ".UnixDate($localDevice{CheckOutTimeStamp}, "%c"));
		print BOLD YELLOW "!!! $localDevice{CurrentUser} must now receive $localDevice{Name}\n";
		return 1;
	}
}

sub checkin {
	my ($bio, $localDevice) = @_;
	my %bio = %{$bio};
	my %localDevice = %{$localDevice};
	message(2, "$bio{gecos} is returning $localDevice{Name} on behalf of ".expanduid($localDevice{CurrentUser})."!") if $bio{uid} ne $localDevice{CurrentUser};
	if ( $bio{uid} eq $localDevice{CurrentUser} || $ENV{behalf} ) {
		$localDevice{CheckInTimeStamp} = ParseDate('now');
		$localDevice{CurrentUser} = $bio{uid};
		my $entry = Net::LDAP::Entry->new;
		$entry->dn($localDevice{dn});
		$entry->changetype('modify');
		$entry->delete('localDeviceCurrentUser') if $localDevice{CurrentUser};
		$entry->replace(
			localDeviceLastUser => $localDevice{CurrentUser},
			localDeviceReturnedBy => $bio{uid},
			localDeviceCheckInTimeStamp => $localDevice{CheckInTimeStamp},
		);
		my $update = $entry->update($ldap);
		if ( $update->code ) {
			print BOLD RED "!!! FATAL ERROR (checkin): Please log transaction on paper.  Suspend all further transactions until error is resolved.\n";
			message(1, $update->error);
		}
		message(2, "$localDevice{Name} returned by $bio{gecos} at ".UnixDate($localDevice{CheckInTimeStamp}, "%c"));
		print BOLD GREEN "!!! $bio{uid} must now return $localDevice{Name}.\n";
		return 1;
	} else {
		message(2, "$bio{gecos} is not authorized to return $localDevice{Name} on behalf of ".expanduid($localDevice{CurrentUser}).".  Transaction cancelled!!");
		return undef;
	}
}
