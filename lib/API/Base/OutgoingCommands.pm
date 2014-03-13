# Copyright (c) 2012, Mitchell Cooper
package API::Base::OutgoingCommands;

use warnings;
use strict;

use utils 'log2';

our $VERSION = $ircd::VERSION;

sub register_outgoing_command {
    my ($mod, %opts) = @_;

    # make sure all required options are present
    foreach my $what (qw|name code|) {
        next if exists $opts{$what};
        $opts{name} ||= 'unknown';
        log2("outgoing command $opts{name} does not have '$what' option.");
        return
    }

    $mod->{user_commands} ||= [];

    # register to juno
    $::pool->register_outgoing_handler(
        $mod->{name},
        $opts{name},
        $opts{code}
    ) or return;

    push @{ $mod->{outgoing_commands} }, $opts{name};
    return 1
}

sub _unload {
    my ($class, $mod) = @_;
    log2("unloading outgoing commands registered by $$mod{name}");
    $::pool->delete_outgoing_handler($_) foreach @{ $mod->{outgoing_commands} };
    log2("done unloading commands");
    return 1
}

1
