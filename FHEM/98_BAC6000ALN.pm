################################################################################
# $Id: 98_BAC6000ALN.pm 23484 2022-12-20 14:02:43Z JensWagner $
#
# fhem Modul für BECA Klimaanlagen-Thermostate mit RS485 Modbus-Interface
# verwendet Modbus.pm als Basismodul für die eigentliche Implementation des Protokolls.
#
# Siehe ModbusExample.pm für eine ausführlichere Infos zur Verwendung des Moduls 
# 98_Modbus.pm 
#
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
##############################################################################
#   Changelog:
#
#   2022-12-20  initial release
#

package main;
use strict;
use warnings;

use Data::Dumper;

sub BAC6000ALN_Initialize($);



my %BAC6000ALNparseInfo = (
    "h0"    =>  {   reading => "Power",
                    map     => '0:off, 1:on',
                    set     => 1,
                },
    "h1"    =>  {   reading => "FanSpeed",
                    map     => '0:auto, 1:high, 2:medium, 3:low',
                    set     => 1,
                },
    "h2"    =>  {   reading => "Mode",
                    expr    => 'BAC6000ALN__CallbackModeExpr($val, $name)',
                    map     => '0:cooling, 1:heating, 2:ventilation',
                    set     => 1,
                },
    "h3"    =>  {   reading => "Temperature",
                    expr    => '$val/10',
                    format  => '%.1f',
                    set     => 1,
                    setexpr => '$val * 10',
                },
    "h4"    =>  {   reading => "Lock",
                    map     => '0:disabled, 1:enabled',
                    set     => 1,
                },
    "h5"    =>  {   reading => "Time", # Special code to combine Minute and Hour registers into time format
                    len     => 2,
                    unpack  => 'N',
                    textArg => 1,
#                    expr    => 'sprintf("%2.2d:%2.2d", ($val % 65536),(int($val / 65536)))',
                    expr    => 'BAC6000ALN__CallbackTimeExpr($val, $name)',
                    set     => 1,
                    setexpr => '($val =~ /(\d+)\:(\d+)/)? $1 + $2*65536 : 0',
                },
    "h7"    =>  {   reading => "Weekday",
                    expr    => 'BAC6000ALN__CallbackWeekdayExpr($val, $name)',
                    map     => '1:Monday, 2:Tuesday, 3:Wednesday, 4:Thursday, 5:Friday, 6:Saturday, 7:Sunday',
                    set     => 1,
                },
                
    "h8"    =>  {   reading => "RoomTemperature",
                    expr    => '$val/10',
                    format  => '%.1f',
                },
    "h9"    =>  {   reading => "Valve",
                    map     => '0:off, 1:on',
                },
    "h10"    =>  {  reading => "FanStatus",
                    map     => '0:off, 1:high, 2:medium, 3:low',
                },
);


my %BAC6000ALNdeviceInfo = (
    "timing"    => {
            timeout     =>  3,
    },
    "h"     =>  {
            combine     =>  11,
            defPoll     =>  1,
    },
);


#####################################
sub
BAC6000ALN_Initialize($)
{
    my ($modHash) = @_;

    require "$attr{global}{modpath}/FHEM/98_Modbus.pm";

    ModbusLD_Initialize($modHash);                   # Generic function of the Modbus module does the rest

    $modHash->{parseInfo}  = \%BAC6000ALNparseInfo;  # defines registers, inputs, coils etc. for this Modbus Defive
    
    $modHash->{deviceInfo} = \%BAC6000ALNdeviceInfo; # defines properties of the device like 
                                                     # defaults and supported function codes

	my $SyncAttrList = join " ", qw(
		sync-Mode-source
		sync-FanSpeed-source
		sync-Time:0,1
		sync-Weekday:0,1
	);

    $modHash->{AttrList} = $SyncAttrList . " " . $modHash->{AttrList} . " " .     # Standard Attributes like IODEv etc 
        $modHash->{ObjAttrList} . " " .                     # Attributes to add or overwrite parseInfo definitions
        $modHash->{DevAttrList} . " " .                     # Attributes to add or overwrite devInfo definitions
        "poll-.* " .                                        # overwrite poll with poll-ReadingName
        "polldelay-.* ";                                    # overwrite polldelay with polldelay-ReadingName
}




sub BAC6000ALN__SyncTimer {
	my $hash = shift;
	my $name = $hash->{NAME};
	my $property = $hash->{PROPERTY};
	my $value = $hash->{VALUE};

	Log 5, "BAC6000ALN__SyncTimer: Set $name $property $value";

	RemoveInternalTimer($hash);

	DoSet($name, $property, $value);
}


sub BAC6000ALN__CallbackTimeExpr {
	my $val = shift;
	my $name = shift;
	
	my $time = sprintf("%2.2d:%2.2d", ($val % 65536),(int($val / 65536)));
	
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	
	my $correct_time = sprintf("%02d:%02d", $hour, $min);
	
	if ( $time ne $correct_time ) {
	    Log 5, "BAC6000ALN__CallbackTimeExpr: Time of $name: $time, should be $correct_time";
		InternalTimer(gettimeofday(), "BAC6000ALN__SyncTimer", {NAME => $name, PROPERTY => "Time", VALUE => $correct_time}, 0);
	}

    return $time;
}


sub BAC6000ALN__CallbackWeekdayExpr {
	my $val = shift;
	my $name = shift;
	
	my %weekdays = ();
	%weekdays = map { $` => $' if /\s*:\s*/ } split /\s*,\s*/, $BAC6000ALNparseInfo{h7}{map}
		if exists $BAC6000ALNparseInfo{h7}{map};

	my (undef,undef,undef,undef,undef,undef,$correct_wday) = localtime(time);
	$correct_wday = 7 if $correct_wday == 0;
	$correct_wday = $weekdays{$correct_wday} if exists $weekdays{$correct_wday};
	
	my $val_wday = $val;
	$val_wday = $weekdays{$val} if exists $weekdays{$val};

	if ( $correct_wday ne $val_wday ) {
	    Log 0, "BAC6000ALN__CallbackWeekdayExpr: Weekday of $name: $val_wday, should be $correct_wday";
   		InternalTimer(gettimeofday(), "BAC6000ALN__SyncTimer", {NAME => $name, PROPERTY => "Weekday", VALUE => $correct_wday}, 0);
	}
    
    return $val;
}


sub BAC6000ALN__CallbackModeExpr {
	my $val = shift;
	my $name = shift;
	
	my %modes = ();
	%modes = map { $` => $' if /\s*:\s*/ } split /\s*,\s*/, $BAC6000ALNparseInfo{h2}{map}
		if exists $BAC6000ALNparseInfo{h2}{map};

	my $val_mapped = $val;
	$val_mapped = $modes{$val} if exists $modes{$val};

	my $sync_source = AttrVal($name, "sync-Mode-source", undef);

	if ( defined $sync_source ) {
		my $correct_mode = ReadingsVal($sync_source, 'Mode', $val_mapped);

		if ( $correct_mode ne $val_mapped ) {
			Log 0, "BAC6000ALN__CallbackModeExpr: Mode of $name: $val_mapped, should be $correct_mode";
	   		InternalTimer(gettimeofday(), "BAC6000ALN__SyncTimer", {NAME => $name, PROPERTY => "Mode", VALUE => $correct_mode}, 0);
		}
    }
    
    return $val;
}




1;

=pod
=item device
=item summary Module for BECA Air Conditioning Thermostats BAC6000ALN with RS485 Modbus-RTU
=item summary_DE Modul für BECA Klimaanlagen-Thermostate mit RS485 Modbus-Interface
=begin html


=end html
=cut
