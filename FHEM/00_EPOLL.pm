##############################################
#
# epoll based main loop for fhem
#
# Copyright (C) 2024 Jens Wagner
#
#     This file is part of fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################



use strict;

use IO::Epoll;

use Data::Dumper;

# redefine some variables that are scope limited to fhem.pl

my $gotSig;                     # non-undef if got a signal
my $wbName = ".WRITEBUFFER";    # Buffer-name for delayed writing via select
my $readytimeout = ($^O eq "MSWin32") ? 0.1 : 5.0;

# define some variables to preserve former state

my $save_execFhemTestFile = undef;
my $save_SIG_TERM = undef;
my $save_SIG_USR1 = undef;
my $save_SIG_HUP = undef;


my $epoll_fd = undef;
my %epoll_map = (); # Store items as $p => {FD => EVENTMASK, ...}
my %epoll_slid_by_fd = ();
my %epoll_update_slids = ();
my @epoll_fake_events = ();
my @epoll_check_ssl_read_buffer = ();


sub EPOLL_Initialize {
    my ($modHash) = @_;

    $modHash->{DefFn} = \&EPOLL_Define;

	return;
}


sub EPOLL_Define() {
	my $hash = shift;                     # new hash of the device to be created
	my $def    = shift;                     # definition string 
	my @a      = split(/\s+/, $def);
	my $name   = shift @a;                  # name of the device to be created
	my $type   = shift @a;                  # type / module to be used

	return "Only one EPOLL device may be defined!"
		if defined $save_execFhemTestFile;
		
	# OVERRIDE THE execFhemTestFile sub in fhem.pl to provide the new main loop ;-)
	$save_execFhemTestFile = \&execFhemTestFile;
	*execFhemTestFile = \&EPOLL_execFhemTestFile;

	if ( $fhem_started ) {
		# defined while running already, will only work after restart
		$hash->{STATE} = "waiting for restart";
		Log3 $name, 3, "$name defined, but not activated";
	}
	else {
		Log3 $name, 3, "$name defined and activated";
		$hash->{STATE} = "active";
	}
	return;
}

sub EPOLL_execFhemTestFile() {
	# Call original execFhemTestFile()
	&$save_execFhemTestFile();

	# Enter new main loop
	return EPOLL_Setup();
}


sub EPOLL_UpdateDefHash {
	my $hash = shift;
	my $key = shift; # only used for development/profiling
	
	return unless exists $hash->{FD};
	my ($p) = $epoll_slid_by_fd{$hash->{FD}};
	
	$epoll_update_slids{$p} = 1 if defined $p;
}


sub EPOLL_UpdateSelectlist($) {
	my $p = shift;

	# print STDERR "EPOLL_UpdateSelectlist($p)\n";

	delete $epoll_update_slids{$p};

	my %new_map = ();
	
	if ( exists $selectlist{$p} ) {
		my $hash = $selectlist{$p};
		
		$new_map{$hash->{FD}} = 0
			if exists $hash->{FD};
		$new_map{$hash->{EXCEPT_FD}} = 0 # might be same as FD
			if exists $new_map{$hash->{EXCEPT_FD}};
		
		if(defined($hash->{FD})) {
			$new_map{$hash->{FD}} |= EPOLLIN
				if(!defined($hash->{directWriteFn}) && !$hash->{wantWrite} );
			$new_map{$hash->{FD}} |= EPOLLOUT
				if( (defined($hash->{directWriteFn}) ||
					 defined($hash->{$wbName}) || 
					 $hash->{wantWrite} ) && !$hash->{wantRead} );
		}
		if (defined($hash->{"EXCEPT_FD"})) {
			$new_map{$hash->{EXCEPT_FD}} |= EPOLLPRI;
		}
	}
	
	$epoll_map{$p} = {}
		unless exists $epoll_map{$p};

	my $old_map = $epoll_map{$p};

	foreach my $fd ( keys %new_map ) {
		delete $new_map{$fd}
			unless $new_map{$fd};
	}
	
	foreach my $fd ( keys %new_map ) {

		if ( !exists $old_map->{$fd} ) {
			epoll_ctl($epoll_fd, EPOLL_CTL_ADD, $fd, $new_map{$fd}) >= 0
				|| die "epoll_ctl($epoll_fd, EPOLL_CTL_ADD, $fd, $new_map{$fd}): $!\n";
			$epoll_slid_by_fd{$fd} = $p;
		}
		else {
			if ( $old_map->{$fd} != $new_map{$fd} ) {
				epoll_ctl($epoll_fd, EPOLL_CTL_MOD, $fd, $new_map{$fd}) >= 0
				|| die "epoll_ctl($epoll_fd, EPOLL_CTL_MOD, $fd, $new_map{$fd}): $!\n";
				$epoll_slid_by_fd{$fd} = $p;
			}
			delete $old_map->{$fd};
		}
	}
	foreach my $fd ( keys %$old_map ) {
	
		epoll_ctl($epoll_fd, EPOLL_CTL_DEL, $fd, 0);
		delete $epoll_slid_by_fd{$fd};
	}
	
	if ( %new_map ) {
		$epoll_map{$p} = \%new_map;
	}
	else {
		delete $epoll_map{$p};
	}
}


sub EPOLL_Setup() {

	# OVERRIDE original signal handlers
	my $save_SIG_TERM = $SIG{TERM};
	my $save_SIG_USR1 = $SIG{USR1};
	my $save_SIG_HUP = $SIG{HUP};
	
    $SIG{TERM} = sub { $gotSig = "TERM"; };
    $SIG{USR1} = sub { $gotSig = "USR1"; };
    $SIG{HUP}  = sub { $gotSig = "HUP"; };

	$epoll_fd = epoll_create(100);
	die "epoll_create failed: $!" unless $epoll_fd > 0;


	my %old_selectlist = %selectlist;
	%selectlist = ();
	tie %selectlist, "EPOLL_Hash_Selectlist";
	%selectlist = (%old_selectlist);
	
#	die Dumper(\%selectlist, \%readyfnlist, \%epoll_map);
#	die Dumper(\%selectlist);

	# enter epoll based main loop
	return EPOLL_MainLoop();
}



sub EPOLL_MainLoop() {

	my $errcount= 0;
	$gotSig = undef if($gotSig && $gotSig eq "HUP");

	while (1) {
	
		foreach my $p ( keys %epoll_update_slids ) {
			EPOLL_UpdateSelectlist($p);
		}

#		print STDERR "Prio Queue: ".Dumper(\%prioQueues);
		
		my $timeout = HandleTimeout();
		$timeout = $readytimeout if((%readyfnlist) && (!defined($timeout) || $timeout > $readytimeout));
		$timeout = 5 if $winService->{AsAService} && $timeout > 5;

		foreach my $hash ( @epoll_check_ssl_read_buffer ) {
			if($hash->{FD} && $hash->{SSL} && $hash->{CD} &&
			   $hash->{CD}->can('pending') && $hash->{CD}->pending()) {
			   
			   	# Create fake event for data in SSL read buffer
				push @epoll_fake_events, [$hash->{FD}, EPOLLIN];
			}
		}		
		@epoll_check_ssl_read_buffer = ();

		my $events;
		
		if ( @epoll_fake_events ) {
			# needed to simulate EPOLLIN for data in SSL read buffer
		
			$events = [@epoll_fake_events];
			@epoll_fake_events = ();
		}
		else {

			$events = epoll_wait($epoll_fd, 100, int($timeout*1000))
					|| die "epoll_wait: $!\n";;
		}
		
#		print STDERR Dumper($epoll_fd, \%epoll_map, $timeout, $events);

		$winService->{serviceCheck}->() if($winService->{serviceCheck});
	  
		if($gotSig) {
			CommandShutdown(undef, undef) if($gotSig eq "TERM");
			CommandRereadCfg(undef, "")   if($gotSig eq "HUP");
			$attr{global}{verbose} = 5    if($gotSig eq "USR1");
			$gotSig = undef;
		}

		if ( ref $events ) {
			foreach my $e ( @$events ) {
				my ( $fd, $mask ) = @$e;

				if ( exists $epoll_slid_by_fd{$fd} ) {
					my $p = $epoll_slid_by_fd{$fd};
					next unless exists $selectlist{$p}; # Deleted in the loop?

					my $hash = $selectlist{$p};
					my $isDev = ($hash && $hash->{NAME} && $defs{$hash->{NAME}});
					my $isDirect = ($hash && ($hash->{directReadFn} || $hash->{directWriteFn}));
					next if(!$isDev && !$isDirect);


#print STDERR Dumper($hash, $mask);
					
					# Handle read events
					
					if(defined($hash->{FD}) && ($mask & EPOLLIN)) {
						delete $hash->{wantRead};
						if($hash->{directReadFn}) {
							$hash->{directReadFn}($hash);
						}
						else {
							CallFn($hash->{NAME}, "ReadFn", $hash);
						}

						if($hash->{SSL} && $hash->{CD} &&
						   $hash->{CD}->can('pending') && $hash->{CD}->pending()) {
						   
						   	# Data in SSL read buffer? Then check hash on next loop
						   push @epoll_check_ssl_read_buffer, $hash;
						}
					}
					
					# Handle write events

					if(defined($hash->{FD}) && ($mask & EPOLLOUT)) {
						delete $hash->{wantWrite};
						if($hash->{directWriteFn}) {
							$hash->{directWriteFn}($hash);
						}
						elsif(defined($hash->{$wbName})) {
							my $wb = $hash->{$wbName};
							alarm($hash->{ALARMTIMEOUT}) if($hash->{ALARMTIMEOUT});

							my $ret;
							eval { $ret = syswrite($hash->{CD}, $wb); };
							if($@) {
								Log 4, "$hash->{NAME} syswrite: $@";
								if($hash->{TEMPORARY}) {
									TcpServer_Close($hash);
									CommandDelete(undef, $hash->{NAME});
								}
								next;
							}

							my $werr = int($!);
							alarm(0) if($hash->{ALARMTIMEOUT});

							if(!defined($ret) && $werr == EWOULDBLOCK ) {
								$hash->{wantRead} = 1
									if(TcpServer_WantRead($hash));

							}
							elsif(!$ret) { # zero=EOF, undef=error
								Log 4, "$hash->{NAME} write error to $p";
								if($hash->{TEMPORARY}) {
									TcpServer_Close($hash);
									CommandDelete(undef, $hash->{NAME})
								}
							}
							else {
								if($ret >= length($wb)) { # for the > see Forum #29963
									delete($hash->{$wbName});
									if($hash->{WBCallback}) {
										no strict "refs";
										my $ret = &{$hash->{WBCallback}}($hash);
										use strict "refs";
										delete $hash->{WBCallback};
									}
								}
								else {
									$hash->{$wbName} = substr($wb, $ret);
								}
							}
						}
					}

					# Handle exceptions

					if(defined($hash->{"EXCEPT_FD"}) && ($mask & EPOLLPRI)) {
						CallFn($hash->{NAME}, "ExceptFn", $hash);
					}
				}				
				else {
#					die "Invalid FD returned: $fd";
				}
			}
		}

		foreach my $p (keys %readyfnlist) {
			next if(!$readyfnlist{$p});                 # due to rereadcfg / delete

			if(CallFn($readyfnlist{$p}{NAME}, "ReadyFn", $readyfnlist{$p})) {
				if($readyfnlist{$p}) {                    # delete itself inside ReadyFn
					CallFn($readyfnlist{$p}{NAME}, "ReadFn", $readyfnlist{$p});
				}
			}
		}
	}
}




package EPOLL_Hash_Selectlist;

## Helper package to monitor changes to selectlist

use base "Tie::StdHash";
use Data::Dumper;

sub STORE {
	my ($self, $key, $val) = @_;
	
	if ( (ref $val) && (ref $val eq "HASH") ) {
		if ( !tied $val ) {
			my %old = %$val;
			
			tie %$val, "EPOLL_Hash_Device";
			%$val = (%old);			
		}
		
	}

	$self->{$key} = $val;
	
    main::EPOLL_UpdateSelectlist($key);
}


sub DELETE {
	my ($self, $key) = @_;
	delete $self->{$key};
    main::EPOLL_UpdateSelectlist($key);
}



package EPOLL_Hash_Device;

## Helper package to monitor changes to defs

use base "Tie::StdHash";
use Data::Dumper;

sub STORE {
	my ($self, $key, $val) = @_;
	$self->{$key} = $val;
	
    main::EPOLL_UpdateDefHash($self, "+$key")
    	if $key =~ /^(FD|EXCEPT_FD|\.WRITEBUFFER|wantRead|wantWrite|directWriteFn)$/og;
}


sub DELETE {
	my ($self, $key) = @_;
	return unless exists $self->{$key};
	delete $self->{$key};
    main::EPOLL_UpdateDefHash($self, "-$key")
    	if $key =~ /^(FD|EXCEPT_FD|\.WRITEBUFFER|wantRead|wantWrite|directWriteFn)$/og;
}


1;

