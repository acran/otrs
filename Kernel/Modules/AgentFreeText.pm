# --
# Kernel/Modules/AgentText.pm - to set the ticket free text
# Copyright (C) 2001-2003 Martin Edenhofer <martin+code@otrs.org>
# --
# $Id: AgentFreeText.pm,v 1.2 2003-07-08 00:00:37 martin Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

package Kernel::Modules::AgentFreeText;

use strict;

use vars qw($VERSION);
$VERSION = '$Revision: 1.2 $';
$VERSION =~ s/^\$.*:\W(.*)\W.+?$/$1/;

# --
sub new {
    my $Type = shift;
    my %Param = @_;
   
    # allocate new hash for object 
    my $Self = {}; 
    bless ($Self, $Type);
    
    foreach (keys %Param) {
        $Self->{$_} = $Param{$_};
    }

    # check needed Opjects
    foreach (qw(ParamObject DBObject TicketObject LayoutObject LogObject 
      ConfigObject)) {
        die "Got no $_!" if (!$Self->{$_});
    }
   
    return $Self;
}
# --
sub Run {
    my $Self = shift;
    my %Param = @_;
    my $Output;
    # --
    # check needed stuff
    # --
    if (!$Self->{TicketID}) {
        # --
        # error page
        # --
        my $Output = $Self->{LayoutObject}->Header(Title => 'Error');
        $Output .= $Self->{LayoutObject}->Error(
            Message => "No TicketID is given!",
            Comment => 'Please contact the admin.',
        );
        $Output .= $Self->{LayoutObject}->Footer();
        return $Output;
    }
    # --
    # check permissions
    # --
    if (!$Self->{TicketObject}->Permission(
        Type => 'rw',
        TicketID => $Self->{TicketID},
        UserID => $Self->{UserID})) {
        # --
        # error screen, don't show ticket
        # --
        return $Self->{LayoutObject}->NoPermission(WithHeader => 'yes');
    }
    else {
        my ($OwnerID, $OwnerLogin) = $Self->{TicketObject}->CheckOwner(
            TicketID => $Self->{TicketID},
        );
        if ($OwnerID != $Self->{UserID}) {
            $Output .= $Self->{LayoutObject}->Header(Title => 'Error');
            $Output .= $Self->{LayoutObject}->Error(
                Message => "Sorry, the current owner is $OwnerLogin",
                Comment => 'Please change the owner first.',
            );
            $Output .= $Self->{LayoutObject}->Footer();
            return $Output;
        }
    }

    if ($Self->{Subaction} eq 'Update') {
        # --
        # update ticket free text
        # --
        foreach (1..2) {
            my $FreeKey = $Self->{ParamObject}->GetParam(Param => "FreeKey$_") || '';
            my $FreeValue = $Self->{ParamObject}->GetParam(Param => "FreeText$_") || '';
            $Self->{TicketObject}->SetTicketFreeText(
                Key => $FreeKey,
                Value => $FreeValue,
                Counter => $_,
                TicketID => $Self->{TicketID},
                UserID => $Self->{UserID},
            );
        }
        # --
        # print redirect
        # --
        return $Self->{LayoutObject}->Redirect(OP => $Self->{LastScreen});
    }
    else {
        # print form
        my %Ticket = $Self->{TicketObject}->GetTicket(TicketID => $Self->{TicketID});
        $Output .= $Self->{LayoutObject}->Header(Title => 'Set Free Text');
        my %LockedData = $Self->{TicketObject}->GetLockedCount(UserID => $Self->{UserID});
        $Output .= $Self->{LayoutObject}->NavigationBar(LockData => \%LockedData);
        # print change form
	    $Output .= $Self->{LayoutObject}->Output(
                TemplateFile => 'AgentFreeText', 
                Data => {
                    %Ticket,
                    QueueID => $Self->{QueueID},
                },
        );
        $Output .= $Self->{LayoutObject}->Footer();
        return $Output;
    }
}
# --

1;
