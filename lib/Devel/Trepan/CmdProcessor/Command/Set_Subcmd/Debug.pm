# -*- coding: utf-8 -*-
# Copyright (C) 2012, 2014 Rocky Bernstein <rocky@cpan.org>
use warnings; no warnings 'redefine'; no warnings 'once';
use rlib '../../../../..';
use strict;
use vars qw(@ISA @SUBCMD_VARS);

package Devel::Trepan::CmdProcessor::Command::Set::Debug;

use Devel::Trepan::CmdProcessor::Command::Subcmd::Core;
use Devel::Trepan::CmdProcessor::Command::Subcmd::SubsubMgr;
use vars qw(@ISA @SUBCMD_VARS);
our $MIN_ABBREV = length('de');
=pod

=head2 Synopsis:

=cut

our $HELP   = <<"HELP";
=pod

B<set debug> [I<set debug commands>]

Set debugger debugging controls.

Run C<set debug *> for a list of subcommands or C<help set debug> I<name>
for help on a particular debugging control.

=head2 See also:

L<C<show debug>|Devel::Trepan::CmdProcessor::Command::Show::Debug>,
L<C<set debug
except>|Devel::Trepan::CmdProcessor::Command::Set::Debug::Except>,
L<C<set debug
macro>|Devel::Trepan::CmdProcessor::Command::Set::Debug::Macro>, and
L<C<set debug
skip>|Devel::Trepan::CmdProcessor::Command::Set::Debug::Skip>,

=cut

HELP
our $SHORT_HELP = "Set debugging controls";

@ISA = qw(Devel::Trepan::CmdProcessor::Command::SubsubcmdMgr);


# sub run($$)
# {
#     my ($self, $args) = @_;
#     $self->SUPER;
# }

unless (caller) {
    # Demo it.
    require Devel::Trepan;
    # Demo it.
    # FIXME: DRY with other subcommand manager demo code.
    require Devel::Trepan::CmdProcessor;
    my $proc = Devel::Trepan::CmdProcessor->new;
    my $parent = Devel::Trepan::CmdProcessor::Command::Set->new($proc, 'set');
    my $cmd = __PACKAGE__->new($parent, 'debug');
    print $cmd->{help}, "\n";
    print "min args: ", $cmd->MIN_ARGS, "\n";
    for my $arg ('e', 'macro', 'foo') {
        my @aref = $cmd->complete_token_with_next($arg);
        printf "%s\n", @aref ? $aref[0]->[0]: 'undef';
    }

    print join(' ', @{$cmd->{prefix}}), "\n";
    $cmd->run($cmd->{prefix});
    # $cmd->run($cmd->{prefix}, ('except', 'on'));
}

1;
