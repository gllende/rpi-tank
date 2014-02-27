#!/usr/bin/perl

# This program allows you to control GPIO pins over network.
# TCP-IP socket is used, by default port is 11700
# Developed for Raspberry Pi GPIO(BCM2835)
# author: Pavel Bondar, 2013-2014
# license: MIT, see LICENCE file for details
#
# How to deal with it:
# - open connection to port 11700
# - send 'set_output 1 3 12' - pins 1 3 12 will be set as 1
#    all other pins will be set as 0.
# - once you are done send 'exit', or 'quit'
# - for debug purpose you can connect via 'telnet localhost 11700',
#   than you can check how daemon reacts on your commands
# - when debugging it is usefull to run daemon with flags 
#   --debug --debug-network --debug-hardware
# --debug-network is needed when you dont want to initialize hardware
#   so specific hardware modules(BMC2835) will not be loaded
# --debug-hardware initialize hardware in debug mode,
#   so gpio pins actually will not be set,
#   just printing what values are gonna be set.

use Getopt::Long;
use File::Touch;
use IO::Socket;
use Fcntl qw(:flock);
use strict;

my ($debug, $debug_network, $debug_hardware, $show_usage);
GetOptions (
	'debug' =>\$debug,
	'debug-network' =>\$debug_network,
	'debug-hardware' =>\$debug_hardware,
	'help' => \$show_usage,
);

usage() if $show_usage;

my $fallback_output;
my $fallback_timeout = 1;
my %pins;
my %commands = (
	'set_output' =>{
		code => \&set_output,
		help => "Set list of pins into high state. Will be set to fallback output values\n" .
			"once fallback timeout has exceeded.\n" .
			"Example 'set_output 23 26'.\n" .
			"If pi-blaster backend is used, allows to set PWM on pin:\n" .
			"Example 'set_output 23=40 26=80', where 23 is a pin, and 40 is 40% PWM for pin 23."
	},
	# fallback output: if fallback timeout is exceeded, 
	'set_fallback_output' =>{
		help =>	"If fallback timeout is exceeded, server set fallback values as output.\n" .
			"Useful to stop in case of connection issues.",
	},
	'set_fallback_timeout' =>{
		code => \&set_fallback_timeout,
		help => 'After timeout have passed fallback_output are set by server as outputs automatically.' .
			"\nHave no effect if unset or 0.",
	},
	'help' => {
		code => \&autogenerate_help,
		help => 'Generate this help.'
	},
	'exit' => {
		code => \&close_connection,
		help => 'Close connection to the client.'
	},
	'quit' => {
		code => \&close_connection,
		help => 'Close connection to the client.'
	},
);
# map real pin number to GPIO pin name
my %pin2gpio = (
	12 => 18, # PIN 12 => GPIO18
	16 => 23,
	18 => 24,
	19 => 10, # pins 19-26 are used for hardware v2
	21 => 9,
	22 => 25,
	23 => 11,
	24 => 8,
	26 => 7,
);

# contains only pins used for hardware version 2
my $avg_values = {
	19 => 0,
	21 => 0,
	22 => 0,
	23 => 0,
	24 => 0,
	26 => 0,
};
my $pi_blaster_device = '/dev/pi-blaster';
my $lock_file = '/tmp/rpi-gpiod.lock';

# Hardware(BMC2835) is specific for Raspberry Pi platform
# so debuging on other platforms can be done using --debug-network flag
init_hardware() unless $debug_network;

my $sock = init_network();

# prevent zombies
$SIG{CHLD} = 'IGNORE';

# Allows only one client for now, no forking
while (1)
{
	my $new_sock = $sock->accept();

	if (my $pid = fork()) {
		debug("Forked successfully");
		next;
	} elsif ($pid == 0) {
		info("Client connected");

		# Reset outputs to default state in case of exceeding $fallback_timeout 
		$SIG{ALRM} = \&reset_output;

		# give user friendly command promt
		$new_sock->send('>');

		while(<$new_sock>) {
			alarm 0;

			info("Receiving transmission: " . $_);
			select_command($new_sock, $_);
			alarm $fallback_timeout;

			$new_sock->send('>');
		}
		close($new_sock) if $new_sock;
		info("Client disconnected");
		exit 0;
	} else {
		info("Failed to fork");
	}
}

sub init_hardware {
	require Device::BCM2835;
	Device::BCM2835::init() || die "Could not init library";

	Device::BCM2835::set_debug(1) if $debug_hardware;

	# hardware pin that can be used for reading/writing
	%pins = (
		12 => &Device::BCM2835::RPI_GPIO_P1_12,
		16 => &Device::BCM2835::RPI_GPIO_P1_16,
		18 => &Device::BCM2835::RPI_GPIO_P1_18,
		19 => &Device::BCM2835::RPI_GPIO_P1_19,
		21 => &Device::BCM2835::RPI_GPIO_P1_21,
		22 => &Device::BCM2835::RPI_GPIO_P1_22,
		23 => &Device::BCM2835::RPI_GPIO_P1_23,
		24 => &Device::BCM2835::RPI_GPIO_P1_24,
		26 => &Device::BCM2835::RPI_GPIO_P1_26,
	);
	# set all controls as outputs
	foreach my $pin (keys %pins){
        	Device::BCM2835::gpio_fsel($pins{$pin}, &Device::BCM2835::BCM2835_GPIO_FSEL_OUTP);
	}
	# set all outputs as 0
	set_pinouts();
}

sub init_network {
	my $sock = new IO::Socket::INET (
				#LocalHost => 'localhost',
				LocalPort => '11700',
				Proto => 'tcp',
				Listen => 1,
				Reuse => 1,
	                      );
	die "Could not create socket: $!\n" unless $sock;
	return $sock;
}

sub select_command {
	my ($sock, $command) = @_;
	if($command =~ /^(\S+)(.*)$/){
		my $cmd = lc($1);
		my @params = split(/\s+/, $2);
		shift @params;	#remove space between command and arguments
		print $sock "Params are ". join(" ", @params)."\n" if ($debug);
		if (exists $commands{$cmd}){
			process_command($sock, $commands{$cmd}, @params);
		} else { 
			$sock->send("Command '$cmd' is not a valid command, try 'help' to see commands list\n");
		}
	}
}

sub process_command {
	my $sock = shift; 
	my $cmd = shift;
	my @args = @_;

	if (ref($cmd) eq 'CODE') {
		&{$cmd}($sock, @args);
	} elsif (ref($cmd) eq 'HASH' && exists $$cmd{code}) {
		&{$$cmd{code}}($sock, @args);
	} else {
		print $sock $cmd;
	}

}

sub close_connection {
	my $sock = shift;

	close($sock);
}

sub set_fallback_timeout {
	my $sock = shift;
	my $timeout = int(shift);

	$fallback_timeout = $timeout if ($timeout > 0 && $timeout < 30);
}

sub set_output {
	my $sock = shift;
	set_pinouts(@_);
}

sub reset_output {
	info("*");
	debug("SIG{ALARM}: resetting output\n");
	set_pinouts($fallback_output);
}

sub set_pinouts {
	my %values = map {$_ => 0} sort keys %pins;
	map {$values{$_} = 1 if exists $values{$_}} @_;
	foreach (@_) {
		# set controls pins grabbed from input to high state, binary format
		if (exists $values{$_}) {
			$values{$_} = 1;
		# set per pin PWM
		} elsif (/(\d+)=(\d+)/ && exists $values{$1}) {
			$values{$1} = $2/100 if $2 >= 0 && $2 <= 100;
		}
	}

	# Exlusively lock gpio_write operations
	# to synhronize all forked processes
	# so only one process set outputs at the same time
	touch($lock_file) unless -s $lock_file;
	open(my $fh, '<', $lock_file) || return info("Unable to open $lock_file, skipping...");
	flock($fh, LOCK_EX) || return info("Ubable to lock $lock_file, skipping...");

	if (-e $pi_blaster_device) {
		set_pinouts_piblaster(\%values);
	} else {
		foreach my $pin (sort keys %values) {
			debug("Set output pin $pin with value $values{$pin}");
			Device::BCM2835::gpio_write($pins{$pin}, $values{$pin} ? 1 : 0);
		}
	}

	# Release lock
	flock($fh, LOCK_UN);
	close($fh);
}

sub update_avg {
	my $input = shift;
	my $increment = 0.02;
	my $start_level = 0.3;

	foreach my $pin (keys %$avg_values) {
		next unless exists $$input{$pin};
		if ($$input{$pin} == 1) {
			$$avg_values{$pin} = $$avg_values{$pin} + $increment;
			$$avg_values{$pin} = 1 if $$avg_values{$pin} > 1;
	                $$avg_values{$pin} = $start_level if $$avg_values{$pin} > 0 && $$avg_values{$pin} < $start_level;
		} elsif ($$input{$pin} > 0 && $$input{$pin} < 1) {
			$$avg_values{$pin} = $$input{$pin};
		} else {
			$$avg_values{$pin} = $$input{$pin};
		}
	}
	return $avg_values;
}

sub set_pinouts_piblaster {
	my $values = shift;

	$values = update_avg($values);
	if(open(my $wh, '>', $pi_blaster_device)) {
		info("Map:\n".join("\n",map {"$pin2gpio{$_} => $$values{$_}"} sort keys %$values)."\n");
		print {$wh} join("\n",map {"$pin2gpio{$_}=$$values{$_}"} keys %$values)."\n";
	} else {
		info("Unable to open $pi_blaster_device");
	}
}

sub autogenerate_help {
	my $sock = shift;

	$sock->send("List of commands:\n");
	foreach my $cmd (sort keys %commands) {
		$sock->send($cmd ." -\n");
		if (ref($commands{$cmd}) eq 'HASH' and exists $commands{$cmd}->{help}){
			# add TAB before each line of help message
			$sock->send(join("\n", map{"\t" . $_} split("\n", $commands{$cmd}->{help}))."\n");
		}
	}
}
# service routines
sub info {
	my $msg = shift;
	print "[$$] $msg\n"; 
}

sub debug {
	my $msg = shift;
	print "[$$] $msg\n" if $debug;
}

sub usage {
	print <<EOF;
This Daemon listens tcp socket and give remote access over TCP/IP to GPIO pins of Raspberry PI.
EOF
exit(0);
}

