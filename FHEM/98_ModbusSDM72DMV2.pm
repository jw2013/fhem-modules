##############################################
##############################################
# $Id: 98_ModbusSDM72DMV2.pm 
#
#	fhem Modul für Stromzähler SDM630M von B+G E-Tech & EASTON
#	verwendet Modbus.pm als Basismodul für die eigentliche Implementation des Protokolls.
#
#	This file is part of fhem.
# 
#	Fhem is free software: you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation, either version 2 of the License, or
#	(at your option) any later version.
# 
#	Fhem is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
#	You should have received a copy of the GNU General Public License
#	along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#	Changelog:
#	2015-01-15	initial release
#	2015-01-29	mit register-len, neue Namen für readings
#	2015-01-31	command reference angepasst
#	2015-02-01	fCodeMap -> devicveInfo Hash, Defaults für: timeouts, delays, Längen, Unpack und Format
#	2015-02-14	führende Nullen entfernt; defaultpolldelay, hint, map eingebaut
#	2015-02-17	defPoll, defShowGet Standards in deviceInfo eingebaut, showget und defaultpoll aus parseInfo entfernt 
#				defaultpoll=once verwendet, x[0-9] Format für defaultpolldelay verwendet
#	2015-02-23	ModbusSDM630M_Define & ModbusSDM630M_Undef entfernt
#				ModbusSDM630M_Initialize angepasst
#				%SDM630MparseInfo --> %parseInfo
#	2015-02-27	alle Register vom SDM630M eingebaut, Zyklenzeiten überarbeitet
#	2015-03-14	Anpassungan an neues 98_Modbus.pm, defaultpoll --> poll, defaultpolldelay --> polldelay,
#				attribute für timing umbenannt,
#				parseInfo --> SDM630MparseInfo, deviceInfo --> SDM630MdeviceInfo
#
##############################################################################
#
# basiert auf dem Modul 98_SDM630DM von Roger, https://forum.fhem.de/index.php/topic,25315.msg274011.html#msg274011
#
#       Changelog:
#       2022-03-27      initial release
#       2022-03-28	Fehler korrigiert
#	2022-04-03	Register h28, h64512 und h64514 korrigiert
#
##############################################################################

package main;

use strict;
use warnings;
use Time::HiRes qw( time );

sub ModbusSDM72DMV2_Initialize($);

# deviceInfo defines properties of the device.
# some values can be overwritten in parseInfo, some defaults can even be overwritten by the user with attributes if a corresponding attribute is added to AttrList in _Initialize.
#
my %SDM72DMV2deviceInfo = (
	"timing"	=>	{
			timeout		=>	2,		# 2 seconds timeout when waiting for a response
			commDelay	=>	0.7,	# 0.7 seconds minimal delay between two communications e.g. a read a the next write,
									# can be overwritten with attribute commDelay if added to AttrList in _Initialize below
			sendDelay	=>	0.7,	# 0.7 seconds minimal delay between two sends, can be overwritten with the attribute
									# sendDelay if added to AttrList in _Initialize function below
			}, 
	"i"			=>	{				# details for "input registers" if the device offers them
			read		=>	4,		# use function code 4 to read discrete inputs. They can not be read by definition.
			defLen		=>	2,		# default length (number of registers) per value ((e.g. 2 for a float of 4 bytes that spans 2 registers)
									# can be overwritten in parseInfo per reading by specifying the key "len"
			combine		=>	30,		# allow combined read of up to 30 adjacent registers during getUpdate
#			combine		=>	1,		# no combined read (read more than one registers with one read command) during getUpdate
			defFormat	=>	"%.1f",	# default format string to use after reading a value in sprintf
									# can be overwritten in parseInfo per reading by specifying the key "format"
			defUnpack	=>	"f>",	# default pack / unpack code to convert raw values, e.g. "n" for a 16 bit integer oder
									# "f>" for a big endian float IEEE 754 floating-point numbers
									# can be overwritten in parseInfo per reading by specifying the key "unpack"
			defPoll		=>	1,		# All defined Input Registers should be polled by default unless specified otherwise in parseInfo or by attributes
			defShowGet	=>	1,		# default für showget Key in parseInfo
			},
	"h"			=>	{				# details for "holding registers" if the device offers them
			read		=>	3,		# use function code 3 to read holding registers.
			write		=>	16,		# use function code 16 to write holding registers (alternative could be 16)
			defLen		=>	2,		# default length (number of registers) per value (e.g. 2 for a float of 4 bytes that spans 2 registers)
									# can be overwritten in parseInfo per reading by specifying the key "len"
			combine		=>	10,		# allow combined read of up to 10 adjacent registers during getUpdate
			defUnpack	=>	"f>",	# default pack / unpack code to convert raw values, e.g. "n" for a 16 bit integer oder
									# "f>" for a big endian float IEEE 754 floating-point numbers
									# can be overwritten in parseInfo per reading by specifying the key "unpack"
			defShowGet	=>	1,		# default für showget Key in parseInfo
			},
);

# %parseInfo:
# r/c/i+adress => objHashRef (h = holding register, c = coil, i = input register, d = discrete input)
# the address is a decimal number without leading 0
#
# Explanation of the parseInfo hash sub-keys:
# name			internal name of the value in the modbus documentation of the physical device
# reading		name of the reading to be used in Fhem
# set			can be set to 1 to allow writing this value with a Fhem set-command
# setmin		min value for input validation in a set command
# setmax		max value for input validation in a set command
# hint			string for fhemweb to create a selection or slider
# expr			perl expression to convert a string after it has bee read
# map			a map string to convert an value from the device to a more readable output string 
# 				or to convert a user input to the machine representation
#				e.g. "0:mittig, 1:oberhalb, 2:unterhalb"				
# setexpr		per expression to convert an input string to the machine format before writing
#				this is typically the reverse of the above expr
# format		a format string for sprintf to format a value read
# len			number of Registers this value spans
# poll			defines if this value is included in the read that the module does every defined interval
#				this can be changed by a user with an attribute
# unpack		defines the translation between data in the module and in the communication frame
#				see the documentation of the perl pack function for details.
#				example: "n" for an unsigned 16 bit value or "f>" for a float that is stored in two registers
# showget		can be set to 1 to allow a Fhem get command to read this value from the device
# polldelay		if a value should not be read in each iteration after interval has passed, 
#				this value can be set to a multiple of interval

my %SDM72DMV2parseInfo = (
# Spannung der Phasen, nur bei jedem 5. Zyklus
	"i0"	=>	{	# input register 0x0000
					name		=> "Phase 1 line to neutral volts",	# internal name of this register in the hardware doc
					reading		=> "Voltage_L1__V",					# name of the reading for this value
#					format		=> '%.1f V',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x5",							# only poll this Value if last read is older than 5*Iteration, otherwiese getUpdate will skip it
				},
	"i2"	=>	{	# input register 0x0002
					name		=> "Phase 2 line to neutral volts",	# internal name of this register in the hardware doc
					reading		=> "Voltage_L2__V",					# name of the reading for this value
#					format		=> '%.1f V',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x5",							# only poll this Value if last read is older than 5*Iteration, otherwiese getUpdate will skip it
				},
	"i4"	=>	{	# input register 0x0004
					name		=> "Phase 1 line to neutral volts",	# internal name of this register in the hardware doc
					reading		=> "Voltage_L3__V",					# name of the reading for this value
#					format		=> '%.1f V',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x5",							# only poll this Value if last read is older than 5*Iteration, otherwiese getUpdate will skip it
				},

# Strom der Phasen
	"i6"	=>	{	# input register 0x0006
					name		=> "Phase 1 current",				# internal name of this register in the hardware doc
					reading		=> "Current_L1__A",					# name of the reading for this value
#					format		=> '%.2f A',						# format string for sprintf
					format		=> '%.2f',							# format string for sprintf
				},
	"i8"	=>	{	# input register 0x0008
					name		=> "Phase 2 current",				# internal name of this register in the hardware doc
					reading		=> "Current_L2__A",					# name of the reading for this value
#					format		=> '%.2f A',						# format string for sprintf
					format		=> '%.2f',							# format string for sprintf
				},
	"i10"	=>	{	# input register 0x000A
					name		=> "Phase 3 current",				# internal name of this register in the hardware doc
					reading		=> "Current_L3__A",					# name of the reading for this value
#					format		=> '%.2f A',						# format string for sprintf
					format		=> '%.2f',							# format string for sprintf
				},

# Leistung in W der Phasen
	"i12"	=>	{	# input register 0x000C, Phase 1: Leistung
					name		=> "Phase 1 power",					# internal name of this register in the hardware doc
					reading		=> "Power_L1__W",					# name of the reading for this value
#					format		=> '%.f W',							# format string for sprintf
					format		=> '%.f',							# format string for sprintf
				},
	"i14"	=>	{	# input register 0x000E, Phase 2: Leistung
					name		=> "Phase 2 power",					# internal name of this register in the hardware doc
					reading		=> "Power_L2__W",					# name of the reading for this value
#					format		=> '%.f W',							# format string for sprintf
					format		=> '%.f',							# format string for sprintf
				},
	"i16"	=>	{	# input register 0x0010, Phase 3: Leistung
					name		=> "Phase 3 power",					# internal name of this register in the hardware doc
					reading		=> "Power_L3__W",					# name of the reading for this value
#					format		=> '%.f W',							# format string for sprintf
					format		=> '%.f',							# format string for sprintf
				},

# Scheinleistung in VA der Phasen
	"i18"	=>	{	# input register 0x0012, Phase 1: Volt Ampere
					name		=> "Phase 1 volt amps",				# internal name of this register in the hardware doc
					reading		=> "Power_L1__VA",					# name of the reading for this value
#					format		=> '%.1f VA',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
				},
	"i20"	=>	{	# input register 0x0014, Phase 2: Volt Ampere
					name		=> "Phase 2 volt amps",				# internal name of this register in the hardware doc
					reading		=> "Power_L2__VA",					# name of the reading for this value
#					format		=> '%.1f VA',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
				},
	"i22"	=>	{	# input register 0x0016, Phase 3: Volt Ampere
					name		=> "Phase 3 volt amps",				# internal name of this register in the hardware doc
					reading		=> "Power_L3__VA",					# name of the reading for this value
#					format		=> '%.1f VA',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
				},

# Blindleistung in VAr
	"i24"	=>	{	# input register 0x0018
					name		=> "Phase 1 volt amps reactive",	# internal name of this register in the hardware doc
					reading		=> "Power_L1__VAr",					# name of the reading for this value
#					format		=> '%.1f VAr',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
				},
	"i26"	=>	{	# input register 0x001A
					name		=> "Phase 2 volt amps reactive",	# internal name of this register in the hardware doc
					reading		=> "Power_L2__VAr",					# name of the reading for this value
#					format		=> '%.1f VAr',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
				},
	"i28"	=>	{	# input register 0x001C
					name		=> "Phase 3 volt amps reactive",	# internal name of this register in the hardware doc
					reading		=> "Power_L3__VAr",					# name of the reading for this value
#					format		=> '%.1f VAr',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
				},

# Leistungsfaktor der Phasen, nur jeden 10. Zyklus
	"i30"	=>	{	# input register 0x001E
					# The power factor has its sign adjusted to indicate the nature of the load.
					# Positive for capacitive and negative for inductive
					name		=> "Phase 1 power factor",			# internal name of this register in the hardware doc
					reading		=> "PowerFactor_L1",				# name of the reading for this value
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x10",							# only poll this Value if last read is older than 10*Iteration, otherwiese getUpdate will skip it
				},
	"i32"	=>	{	# input register 0x0020
					# The power factor has its sign adjusted to indicate the nature of the load.
					# Positive for capacitive and negative for inductive
					name		=> "Phase 2 power factor",			# internal name of this register in the hardware doc
					reading		=> "PowerFactor_L2",				# name of the reading for this value
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x10",							# only poll this Value if last read is older than 10*Iteration, otherwiese getUpdate will skip it
				},
	"i34"	=>	{	# input register 0x0022
					# The power factor has its sign adjusted to indicate the nature of the load.
					# Positive for capacitive and negative for inductive
					name		=> "Phase 3 power factor",			# internal name of this register in the hardware doc
					reading		=> "PowerFactor_L3",				# name of the reading for this value
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x10",							# only poll this Value if last read is older than 10*Iteration, otherwiese getUpdate will skip it
				},


# Durchschnittswerte, nur bei jedem 2. Zyklus
	"i42"	=>	{	# input register 0x002A
					name		=> "Average line to neutral volts",	# internal name of this register in the hardware doc
					reading		=> "Voltage_Avr__V",				# name of the reading for this value
#					format		=> '%.1f V',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x2",							# only poll this Value if last read is older than 2*Iteration, otherwiese getUpdate will skip it
				},
	"i46"	=>	{	# input register 0x002E
					name		=> "Average line current",			# internal name of this register in the hardware doc
					reading		=> "Current_Avr__A",				# name of the reading for this value
#					format		=> '%.1f A',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x2",							# only poll this Value if last read is older than 2*Iteration, otherwiese getUpdate will skip it
				},

# Summenwerte
	"i48"	=>	{	# input register 0x0030
					name		=> "Sum of line currents",			# internal name of this register in the hardware doc
					reading		=> "Current_Sum__A",				# name of the reading for this value
#					format		=> '%.2f A',						# format string for sprintf
					format		=> '%.2f',							# format string for sprintf
				},
	"i52"	=>	{	# input register 0x0034
					name		=> "Total system power",			# internal name of this register in the hardware doc
					reading		=> "Power_Sum__W",					# name of the reading for this value
#					format		=> '%.1f W',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
				},
	"i56"	=>	{	# input register 0x0038
					name		=> "Total system Volt Ampere",		# internal name of this register in the hardware doc
					reading		=> "Power_Sum__VA",					# name of the reading for this value
#					format		=> '%.1f VA',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
				},
	"i60"	=>	{	# input register 0x003C
					name		=> "Total system Volt Ampere reactive",	# internal name of this register in the hardware doc
					reading		=> "Power_Sum__VAr",					# name of the reading for this value
#					format		=> '%.1f VAr',							# format string for sprintf
					format		=> '%.1f',								# format string for sprintf
				},
	"i62"	=>	{	# input register 0x003E
					name		=> "Total system power factor",		# internal name of this register in the hardware doc
					reading		=> "PowerFactor",					# name of the reading for this value
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x10",							# only poll this Value if last read is older than 10*Iteration, otherwiese getUpdate will skip it
				},

# Frequenz, nur bei jedem 5. Zyklus
	"i70"	=>	{	# input register 0x0046
					name		=> "Frequency of supply voltages",	# internal name of this register in the hardware doc
					reading		=> "Frequency__Hz",					# name of the reading for this value
#					format		=> '%.2f Hz',						# format string for sprintf
					format		=> '%.2f',							# format string for sprintf
					polldelay	=> "x5",							# only poll this Value if last read is older than 10*Iteration, otherwiese getUpdate will skip it
				},

# Arbeit, Zyklus: jede Minute
	"i72"	=>	{	# input register 0x0048
					name		=> "Import active energy kWh since last reset",	# internal name of this register in the hardware doc
					reading		=> "Energy_import__kWh",			# name of the reading for this value
#					format		=> '%.3f kWh',						# format string for sprintf
					format		=> '%.3f',							# format string for sprintf
					polldelay	=> 60,								# request only if last read is older than 60 seconds
				},
	"i74"	=>	{	# input register 0x004A
					name		=> "Export active energy kWh since last reset",	# internal name of this register in the hardware doc
					reading		=> "Energy_export__kWh",			# name of the reading for this value
#					format		=> '%.3f kWh',						# format string for sprintf
					format		=> '%.3f',							# format string for sprintf
					polldelay	=> 60,								# request only if last read is older than 60 seconds
				},
# Spannung zwischen den Phasen, nur bei jedem 5. Zyklus
	"i200"	=>	{	# input register 0x00C8
					name		=> "Line1 to Line2 volts",			# internal name of this register in the hardware doc
					reading		=> "Voltage_L1_to_L2__V",			# name of the reading for this value
#					format		=> '%.1f V',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x5",							# only poll this Value if last read is older than 5*Iteration, otherwiese getUpdate will skip it
				},
	"i202"	=>	{	# input register 0x00CA
					name		=> "Line2 to Line3 volts",			# internal name of this register in the hardware doc
					reading		=> "Voltage_L2_to_L3__V",			# name of the reading for this value
#					format		=> '%.1f V',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x5",							# only poll this Value if last read is older than 5*Iteration, otherwiese getUpdate will skip it
				},
	"i204"	=>	{	# input register 0x00CC
					name		=> "Line3 to Line1 volts",			# internal name of this register in the hardware doc
					reading		=> "Voltage_L3_to_L1__V",			# name of the reading for this value
#					format		=> '%.1f V',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x5",							# only poll this Value if last read is older than 5*Iteration, otherwiese getUpdate will skip it
				},
	"i206"	=>	{	# input register 0x00CE
					name		=> "Average line to line volts",	# internal name of this register in the hardware doc
					reading		=> "Voltage_Avr_L_to_L__V",			# name of the reading for this value
#					format		=> '%.1f V',						# format string for sprintf
					format		=> '%.1f',							# format string for sprintf
					polldelay	=> "x10",							# only poll this Value if last read is older than 5*Iteration, otherwiese getUpdate will skip it
				},

# Strom
	"i224"	=>	{	# input register 0x00E0
					name		=> "Neutral current",				# internal name of this register in the hardware doc
					reading		=> "Current_N__A",					# name of the reading for this value
#					format		=> '%.2f A',						# format string for sprintf
					format		=> '%.2f',							# format string for sprintf
				},

# kWh Gesamtwerte, Zyklus: jede Minute
	"i342"	=>	{	# input register 0x0156
					name		=> "Total active energy kWh",		# internal name of this register in the hardware doc
					reading		=> "Energy_total__kWh",				# name of the reading for this value
#					format		=> '%.3f kWh',						# format string for sprintf
					format		=> '%.3f',							# format string for sprintf
					polldelay	=> 60,								# request only if last read is older than 60 seconds
				},
	"i344"	=>	{	# input register 0x0158
					name		=> "Total reactive kVArh",			# internal name of this register in the hardware doc
					reading		=> "Energy_total__kVArh",			# name of the reading for this value
#					format		=> '%.3f kVArh',					# format string for sprintf
					format		=> '%.3f',							# format string for sprintf
					polldelay	=> 60,								# request only if last read is older than 60 seconds
				},

###############################################################################################################
# Holding Register
###############################################################################################################

	"h10"	=>	{	# holding register 0x000A
					# Write system type: 1=1p2w, 3=3p4w
					# Requires password, see register Password 0x0018
					name		=> "System Type",					# internal name of this register in the hardware doc
					reading		=> "System_Type",					# name of the reading for this value
					map		=> "1:1p2w, 3:3p4w",					# map to convert visible values to internal numbers (for reading and writing)
					hint		=> "1p2w,3p4w",							# string for fhemweb to create a selection or slider
					poll		=> "once",							# only poll once after define (or after a set)
					set			=> 1,								# this value can be set
				},

	"h12"	=>	{	# holding register 0x000C
					# Write relay on period in milliseconds: 60, 100 or 200, default 100
					# If oulse output = 1000imp/kWh, then pulse width is fixed at 35ms and cannot be adjusted
					name		=> "Pulse Width",					# internal name of this register in the hardware doc
					reading		=> "System_Pulse_Width__ms",		# name of the reading for this value
					format		=> '%.f ms',						# format string for sprintf
					hint		=> "60,100,200",					# string for fhemweb to create a selection or slider
					poll		=> "once",							# only poll once after define (or after a set)
					set			=> 1,								# this value can be set
				},

	"h14"	=>	{	# holding register 0x000E
					# Write any value to password lock protected registers.
					# Read password lock status: 0=not authorized, 1=authorized
					# Reading will also reset the password timeout back to one minute.
					name		=> "Key Parameter Programming Authorization (KPPA)",					# internal name of this register in the hardware doc
					reading		=> "KPPA_authorization",			# name of the reading for this value
					map		=> "0:not_authorized, 1:authorized",	# map to convert visible values to internal numbers (for reading and writing)
					hint		=> "not_authorized,authorized",							# string for fhemweb to create a selection or slider
					poll		=> "once",							# only poll once after define (or after a set)
					set		=> 1,								# this value can be set
				},

	"h18"	=>	{	# holding register 0x0012
					# Write the network port parity/stop bits for MODBUS Protocol, where:
					# 0 = One stop bit and no parity, default.
					# 1 = One stop bit and even parity.
					# 2 = One stop bit and odd parity.
					# 3 = Two stop bits and no parity.
					# Requires a restart to become effective.
					name		=> "Network Parity Stop",			# internal name of this register in the hardware doc
					reading		=> "Modbus_Parity_Stop",			# name of the reading for this value
					map		=> "0:1stop.bit_no.parity, 1:1stop.bit_even.parity, 2:1stop.bit_odd.parity, 3:2stop.bits_no.parity",	# map to convert visible values to internal numbers (for reading and writing)
					hint		=> "1stop.bit_no.parity,1stop.bit_even.parity,1stop.bit_odd.parity,2stop.bits_no.parity",						# string for fhemweb to create a selection or slider
					poll		=> "once",							# only poll once after define (or after a set)
					set			=> 1,								# this value can be set
				},

	"h20"	=>	{	# holding register 0x0014
					# Write the network port node address: 1 to 247 for MODBUS Protocol, default 1.
					# Requires a restart to become effective.
					name		=> "Network Node",					# internal name of this register in the hardware doc
					reading		=> "Modbus_Node_adr",				# name of the reading for this value
					min		=> 1,								# input validation for set: min value
					max		=> 247,								# input validation for set: max value
					poll		=> "once",							# only poll once after define (or after a set)
					set		=> 1,								# this value can be set
				},

	"h22"	=>	{	# holding register 0x0016
					# Write pulse constant
					# 0=1000imp/kWh; 1=100imp/kWh; 2=10imo/kWh; 3=1imp/kWh
					name		=> "Pules constant",				# internal name of this register in the hardware doc
					reading		=> "Pulse_constant",				# name of the reading for this value
					map		=> "0:1000imp/kWh,1:100imp/kWh,2:10imp/kWh,3:1imp/kWh",	# map to convert visible values to internal numbers (for reading and writing)
					hint		=> "1000imp/kWh,100imp/kWh,10imp/kWh,1imp/kWh",							# string for fhemweb to create a selection or slider
					poll		=> "once",							# only poll once after define (or after a set)
					set			=> 1,								# this value can be set
				},

	"h24"	=>	{	# holding register 0x0018
					# Write password for access to protected registers.
					name		=> "Password",						# internal name of this register in the hardware doc
					reading		=> "System_Password",				# name of the reading for this value
					set		=> 1,								# this value can be set
				},

	"h28"	=>	{	# holding register 0x001C
					# Write the network port baud rate for MODBUS Protocol, where:
					# 0=2400; 1=4800; 2=9600 (default); 3=19200; 4=38400;
					# Requires no restart, wird sofort active!
					name		=> "Network Baud Rate",				# internal name of this register in the hardware doc
					reading		=> "Modbus_Speed__baud",			# name of the reading for this value
					map		=> "0:2400, 1:4800, 2:9600, 3:19200, 5:1200",	# map to convert visible values to internal numbers (for reading and writing)
					hint		=> "1200,2400,4800,9600,19200",						# string for fhemweb to create a selection or slider
					poll		=> "once",							# only poll once after define (or after a set)
					set			=> 1,								# this value can be set
				},

	"h58"   =>      {       # holding register 0x003A
                                        # Automatic Scroll Display Time
                                        # default 0 sec
                                        # Range 0~60 0 
                                        name            => "Automatic Scroll Display Time",		# internal name o$
                                        reading         => "scrollDisplaytime",				# name of the rea$
                                        format          => '%.f sec',                                   # format string f$
                                        min             => 0,                                           # input validatio$
                                        max             => 60,						# input validatio$
                                        poll            => "once",					# only poll once $
                                        set             => 1,						# this value can $
                                },

	"h60"	=>	{	# holding register 0x003C
					# Backlit time
					# default 60 min
					# Range 0~121 0 means backlit always on, 121 means backlich always of
					name		=> "Time of back light",			# internal name of this register in the hardware doc
					reading		=> "Time__bl",					# name of the reading for this value
					format		=> '%.f min',					# format string for sprintf
					min		=> 0,						# input validation for set: min value
					max		=> 120,						# input validation for set: max value
					poll		=> "once",					# only poll once after define (or after a set)
					set		=> 1,						# this value can be set
			},

	"h86"	=>	{	# holding register 0x0056
					# Write MODBUS Protocol input parameter for pulse relay 1:
					# 1:import active energy; 2:total active energy; 4:export active energy (default)
					name		=> "Pulse l Energy Type",		# internal name of this register in the hardware doc
					reading		=> "Pulse_1_Energy_Type",		# name of the reading for this value
					map		=> "1:ImportActiveEnergy, 2:TotalActiveEnergy, 4:ExportActiveEnergy",	# map to convert visible values to internal numbers (for reading and writing)
					hint		=> "ImportActiveEnergy,TotalActiveEnergy,ExportActiveEnergy",	#string for fhemweb to create a selectin or slider
					#format		=> '%.f',				# format string for sprintf
					poll		=> "once",				# not be polled by default, unless specified otherwise by attributes
					set		=> 1,					# this value can be set
			},
					
	"h64512"=>	{	# holding register 0xFC00
					name		=> "Serial Number",		# internal name of this register in the hardware doc
					reading		=> "System_Serial_Nr",		# name of the reading for this value
					unpack		=> "I*",			# unsigned int32 pack / unpack code to convert raw values
					format		=> '%u',			# format string for sprintf
					poll		=> "once",			# only poll once after define (or after a set)
					showget		=> 1,
			},					

	"h64514"=>      {       # holding register 0xFC02
                                        name            => "Meter code",            # internal name of this $
                                        reading         => "System_Meter_Code",     # name of the reading for this v$
					unpack			=> "H*",					# hex pack / unpack code to convert raw values
					format          => '%s',                    # format string $
                                        poll            => "once",                  # only poll once$
					showget			=> 1,                                
			},

# Ende parseInfo
);


#####################################
sub
ModbusSDM72DMV2_Initialize($)
{
    my ($modHash) = @_;

	require "$attr{global}{modpath}/FHEM/98_Modbus.pm";

	$modHash->{parseInfo}  = \%SDM72DMV2parseInfo;			# defines registers, inputs, coils etc. for this Modbus Defive

	$modHash->{deviceInfo} = \%SDM72DMV2deviceInfo;			# defines properties of the device like 
									# defaults and supported function codes

	ModbusLD_Initialize($modHash);					# Generic function of the Modbus module does the rest

	$modHash->{AttrList} = $modHash->{AttrList} . " " .		# Standard Attributes like IODEv etc 
		$modHash->{ObjAttrList} . " " .				# Attributes to add or overwrite parseInfo definitions
		$modHash->{DevAttrList} . " " .				# Attributes to add or overwrite devInfo definitions
		"poll-.* " .						# overwrite poll with poll-ReadingName
		"polldelay-.* ";					# overwrite polldelay with polldelay-ReadingName
}


1;

=pod
=begin html

<a name="ModbusSDM72DMV2"></a>
<h3>ModbusSDM72DMV2</h3>
<ul>
    ModbusSDM72DMV2 uses the low level Modbus module to provide a way to communicate with SDM72DM-V2 smart electrical meter from B+G E-Tech & EASTON.
	It defines the modbus input and holding registers and reads them in a defined interval.
	
	<br>
    <b>Prerequisites</b>
    <ul>
        <li>
          This module requires the basic Modbus module which itsef requires Device::SerialPort or Win32::SerialPort module.
        </li>
    </ul>
    <br>

    <a name="ModbusSDM72DMV2Define"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; ModbusSDM72DMV2 &lt;Id&gt; &lt;Interval&gt;</code>
        <br><br>
        The module connects to the smart electrical meter with Modbus Id &lt;Id&gt; through an already defined modbus device and actively requests data from the 
        smart electrical meter every &lt;Interval&gt; seconds <br>
        <br>
        Example:<br>
        <br>
        <ul><code>define SDM72DMV2 ModbusSDM72DMV2 1 60</code></ul>
    </ul>
    <br>

    <a name="ModbusSDM72DMV2Configuration"></a>
    <b>Configuration of the module</b><br><br>
    <ul>
        apart from the modbus id and the interval which both are specified in the define command there is nothing that needs to be defined.
		However there are some attributes that can optionally be used to modify the behavior of the module. <br><br>
        
        The attributes that control which messages are sent / which data is requested every &lt;Interval&gt; seconds are:

        <pre>
		poll-Energy_total__kWh
		poll-Energy_import__kWh
		poll-Energy_L1_total__kWh
		poll-Energy_L2_total__kWh
		poll-Energy_L3_total__kWh
		</pre>
        
        if the attribute is set to 1, the corresponding data is requested every &lt;Interval&gt; seconds. If it is set to 0, then the data is not requested.
        by default the temperatures are requested if no attributes are set.
        <br><br>
        Example:
        <pre>
        define SDM72DMV2 ModbusSDM72DMV2 1 60
        attr SDM72DMV2 poll-Energy_total__kWh 0
        </pre>
    </ul>

    <a name="ModbusSDM72DMV2"></a>
    <b>Set-Commands</b><br>
    <ul>
        The following set options are available:
        <pre>
        </pre>
    </ul>
	<br>
    <a name="ModbusSDM72DMV2Get"></a>
    <b>Get-Commands</b><br>
    <ul>
        All readings are also available as Get commands. Internally a Get command triggers the corresponding 
        request to the device and then interprets the data and returns the right field value. To avoid huge option lists in FHEMWEB, only the most important Get options
        are visible in FHEMWEB. However this can easily be changed since all the readings and protocol messages are internally defined in the modue in a data structure 
        and to make a Reading visible as Get option only a little option (e.g. <code>showget => 1</code> has to be added to this data structure
    </ul>
	<br>
    <a name="ModbusSDM72DMV2attr"></a>
    <b>Attributes</b><br><br>
    <ul>
	<li><a href="#do_not_notify">do_not_notify</a></li>
        <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
        <br>
		<li><b>poll-Energy_total__kWh</b></li> 
		<li><b>poll-Energy_import__kWh</b></li> 
		<li><b>poll-Energy_L1_total__kWh</b></li> 
		<li><b>poll-Energy_L2_total__kWh</b></li> 
		<li><b>poll-Energy_L3_total__kWh</b></li> 
            include a read request for the corresponding registers when sending requests every interval seconds <br>
        <li><b>timeout</b></li> 
            set the timeout for reads, defaults to 2 seconds <br>
		<li><b>minSendDelay</b></li> 
			minimal delay between two requests sent to this device
		<li><b>minCommDelay</b></li>  
			minimal delay between requests or receptions to/from this device
    </ul>
    <br>
</ul>

=end html
=cut
