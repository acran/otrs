# --
# Kernel/System/Ticket.pm - the global ticket handle
# Copyright (C) 2001-2004 Martin Edenhofer <martin+code@otrs.org>
# --
# $Id: Ticket.pm,v 1.91 2004-04-18 13:59:02 martin Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

package Kernel::System::Ticket;

use strict;
use Time::Local;
use Kernel::System::Time;
use Kernel::System::Ticket::Article;
use Kernel::System::State;
use Kernel::System::Lock;
use Kernel::System::Queue;
use Kernel::System::User;
use Kernel::System::Group;
use Kernel::System::CustomerUser;
use Kernel::System::CustomerGroup;
use Kernel::System::Email;
use Kernel::System::AutoResponse;
use Kernel::System::StdAttachment;
use Kernel::System::PostMaster::LoopProtection;
use Kernel::System::CustomerUser;
use Kernel::System::Notification;

use vars qw(@ISA $VERSION);
$VERSION = '$Revision: 1.91 $';
$VERSION =~ s/^\$.*:\W(.*)\W.+?$/$1/;

=head1 NAME

Kernel::System::Ticket - ticket lib

=head1 SYNOPSIS

All ticket functions.

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create a object 
 
  use Kernel::Config;
  use Kernel::System::Log;
  use Kernel::System::DB;
  use Kernel::System::Ticket;

  my $ConfigObject = Kernel::Config->new();
  my $LogObject    = Kernel::System::Log->new(
      ConfigObject => $ConfigObject,
  );
  my $DBObject = Kernel::System::DB->new( 
      ConfigObject => $ConfigObject,
      LogObject => $LogObject,
  );
  my $TicketObject = Kernel::System::Ticket->new(
      ConfigObject => $ConfigObject,
      LogObject => $LogObject,
      DBObject => $DBObject,
  );

=cut

# --
sub new {
    my $Type = shift;
    my %Param = @_;

    # allocate new hash for object
    my $Self = {}; 
    bless ($Self, $Type);

    # 0=off; 1=on;
    $Self->{Debug} = $Param{Debug} || 0;
    # create common needed module objects
    $Self->{TimeObject} = Kernel::System::Time->new(%Param);
    $Self->{UserObject} = Kernel::System::User->new(%Param);
    $Self->{GroupObject} = Kernel::System::Group->new(%Param);
    $Self->{CustomerUserObject} = Kernel::System::CustomerUser->new(%Param);
    $Self->{CustomerGroupObject} = Kernel::System::CustomerGroup->new(%Param);
    $Self->{QueueObject} = Kernel::System::Queue->new(%Param);
    $Self->{SendmailObject} = Kernel::System::Email->new(%Param);
    $Self->{AutoResponse} = Kernel::System::AutoResponse->new(%Param);
    $Self->{LoopProtectionObject} = Kernel::System::PostMaster::LoopProtection->new(%Param);
    $Self->{StdAttachmentObject} = Kernel::System::StdAttachment->new(%Param);
    $Self->{StateObject} = Kernel::System::State->new(%Param);
    $Self->{LockObject} = Kernel::System::Lock->new(%Param);
    $Self->{CustomerUserObject} = Kernel::System::CustomerUser->new(%Param);
    $Self->{NotificationObject} = Kernel::System::Notification->new(%Param);
    # get needed objects
    foreach (qw(ConfigObject LogObject DBObject)) {
        $Self->{$_} = $Param{$_} || die "Got no $_!";
    }
    # get config static var
    my @ViewableStates = $Self->{StateObject}->StateGetStatesByType(
        Type => 'Viewable', 
        Result => 'Name',
    );
    $Self->{ViewableStates} = \@ViewableStates;
    my @ViewableStateIDs = $Self->{StateObject}->StateGetStatesByType( 
        Type => 'Viewable',
        Result => 'ID',
    );
    $Self->{ViewableStateIDs} = \@ViewableStateIDs;
    my @ViewableLocks = $Self->{LockObject}->LockViewableLock(Type => 'Name');
    $Self->{ViewableLocks} = \@ViewableLocks;
    my @ViewableLockIDs = $Self->{LockObject}->LockViewableLock(Type => 'ID');
    $Self->{ViewableLockIDs} = \@ViewableLockIDs;
    # get config static var
    $Self->{Sendmail} = $Self->{ConfigObject}->Get('Sendmail');
    $Self->{SendmailBcc} = $Self->{ConfigObject}->Get('SendmailBcc');
    $Self->{FQDN} = $Self->{ConfigObject}->Get('FQDN');
    $Self->{Organization} = $Self->{ConfigObject}->Get('Organization');

    # --
    # load ticket number generator 
    # --
    my $GeneratorModule = $Self->{ConfigObject}->Get('TicketNumberGenerator') 
      || 'Kernel::System::Ticket::Number::AutoIncrement';
    if (!eval "require $GeneratorModule") {
        die "Can't load ticket number generator backend module $GeneratorModule! $@";
    }
    push(@ISA, $GeneratorModule);
    # --
    # load ticket index generator 
    # --
    my $GeneratorIndexModule = $Self->{ConfigObject}->Get('TicketIndexModule')
      || 'Kernel::System::Ticket::IndexAccelerator::RuntimeDB';
    if (!eval "require $GeneratorIndexModule") {
        die "Can't load ticket index backend module $GeneratorIndexModule! $@";
    }
    # --
    # load article storage module 
    # --
    my $StorageModule = $Self->{ConfigObject}->Get('TicketStorageModule')
      || 'Kernel::System::Ticket::ArticleStorageDB';
    if (!eval "require $StorageModule") {
        die "Can't load ticket storage backend module $StorageModule! $@";
    }
    # --
    # load custom functions 
    # --
    my $CustomModule = $Self->{ConfigObject}->Get('TicketCustomModule');
    if ($CustomModule) { 
        if (!eval "require $CustomModule") {
            die "Can't load ticket custom module $CustomModule! $@";
        }
    }
    
    $Self->Init();

    return $Self;
}
# --
sub Init {
    my $Self = shift;
    $Self->ArticleStorageInit();
    return 1;
}
# --

=item TicketCreateNumber()

creates a new ticket number

  my $TicketNumber = $TicketObject->TicketCreateNumber();

=cut

# just for compat
sub TicketCreateNumber {
    my $Self = shift;
    return $Self->CreateTicketNr(@_);
}

=item TicketCheckNumber()

checks if the ticket number exists, returns ticket id if exists

  my $TicketID = $TicketObject->TicketCheckNumber(Tn => '200404051004575');

=cut

# just for compat
sub CheckTicketNr {
    my $Self = shift;
    return $Self->TicketCheckNumber(@_);
}
sub TicketCheckNumber {
    my $Self = shift;
    my %Param = @_;
    my $Id = '';
    # check needed stuff
    if (!$Param{Tn}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need TN!");
      return;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db query
    $Self->{DBObject}->Prepare(
        SQL => "SELECT id FROM ticket " .
          " WHERE " .
          " tn = '$Param{Tn}' ",
    );
    while (my @RowTmp = $Self->{DBObject}->FetchrowArray()) {
        $Id = $RowTmp[0];
    }
    return $Id;
}
# --

=item TicketCreate()

creates a new ticket

  my $TicketID = $TicketObject->TicketCreate(
        TN => $TicketObject->TicketCreateNumber(),
        QueueID => 123,
        Lock => 'unlock',
        GroupID => 1,
        Priority => '3 normal'
        State => 'new',
        CustomerNo => '123465',
        CustomerUser => 'customer@example.com', 
        UserID => 123, # new owner
        CreateUserID => 123, 
  );

=cut

sub TicketCreate {
    my $Self = shift;
    my %Param = @_;
    my $GroupID = $Param{GroupID};
    my $Answered = $Param{Answered} || 0;
    my $ValidID = $Param{ValidID} || 1;
    my $Age = $Self->{TimeObject}->SystemTime();
    # check needed stuff
    foreach (qw(QueueID UserID CreateUserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # StateID/State lookup!
    if (!$Param{StateID}) {
        my %State = $Self->{StateObject}->StateGet(Name => $Param{State});
        $Param{StateID} = $State{ID}; 
    }
    elsif (!$Param{State}) {
        my %State = $Self->{StateObject}->StateGet(ID => $Param{StateID}); 
        $Param{State} = $State{Name}; 
    }
    if (!$Param{StateID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "No StateID!!!");
        return;
    }
    # LockID lookup!
    if (!$Param{LockID} && $Param{Lock}) {
        $Param{LockID} = $Self->{LockObject}->LockLookup(Type => $Param{Lock});
    }
    if (!$Param{LockID} && !$Param{Lock}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "No LockID and no LockType!!!");
        return;
    }
    # PriorityID/Priority lookup!
    if (!$Param{PriorityID} && $Param{Priority}) {
        $Param{PriorityID} = $Self->PriorityLookup(Type => $Param{Priority});
    }
    elsif ($Param{PriorityID} && !$Param{Priority}) {
        $Param{Priority} = $Self->PriorityLookup(ID => $Param{PriorityID});
    }
    if (!$Param{PriorityID} && !$Param{Priority}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "No PriorityID and no PriorityType!!!");
        return;
    }
    # create ticket number if not given
    if (!$Param{TN}) {
        $Param{TN} = $Self->CreateTicketNr();
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # create db record
    my $SQL = "INSERT INTO ticket (tn, create_time_unix, queue_id, ticket_lock_id, ".
    " user_id, group_id, ticket_priority_id, ticket_state_id, ticket_answered, ".
    " valid_id, create_time, create_by, change_time, change_by) " .
    " VALUES ('$Param{TN}', $Age, $Param{QueueID}, $Param{LockID}, $Param{UserID}, ".
    " $GroupID, $Param{PriorityID}, $Param{StateID}, ".
    " $Answered, $ValidID, " .
    " current_timestamp, $Param{CreateUserID}, current_timestamp, $Param{CreateUserID})";

    if ($Self->{DBObject}->Do(SQL => $SQL)) {
        # get ticket id
        my $TicketID = $Self->TicketIDLookup(
            TicketNumber => $Param{TN}, 
            UserID => $Param{UserID},
        );
        # history insert
        my $Queue = $Self->{QueueObject}->QueueLookup(QueueID => $Param{QueueID});
        $Self->HistoryAdd(
            TicketID => $TicketID,
            HistoryType => 'NewTicket',
            Name => "\%\%$Param{TN}\%\%$Queue\%\%$Param{Priority}\%\%$Param{State}\%\%$TicketID",
            CreateUserID => $Param{UserID},
        );
        # set customer data if given
        if ($Param{CustomerNo} || $Param{CustomerUser}) {
            $Self->SetCustomerData(
                TicketID => $TicketID,
                No => $Param{CustomerNo} || '',
                User => $Param{CustomerUser} || '',
                UserID => $Param{UserID},
            );
        }
        # update ticket view index
        $Self->TicketAcceleratorAdd(TicketID => $TicketID);
        # return ticket id
        return $TicketID;
    }
    else {
        $Self->{LogObject}->Log(Priority => 'error', Message => "create db record failed!!!");
        return;
    } 
}
# --

=item TicketDelete()

deletes a ticket from storage 

  $TicketObject->TicketDelete(
      TicketID => 123,
      UserID => 123,
  );

=cut

sub TicketDelete {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    if ($Self->{DBObject}->Do(SQL => "DELETE FROM ticket WHERE id = $Param{TicketID}")) {
        # clear ticket cache
        $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
        # update ticket index
        $Self->TicketAcceleratorDelete(%Param);
        # delete articles
        $Self->ArticleDelete(%Param);
        return 1;
    }
    else {
        return;
    }
}
# --

=item TicketIDLookup()

ticket id lookup by ticket number 

  my $TicketID = $TicketObject->TicketIDLookup(
      TicketNumber => '2004040510440485',
      UserID => 123,
  );

=cut

sub TicketIDLookup {
    my $Self = shift;
    my %Param = @_;
    my $Id;
    # check needed stuff
    if (!$Param{TicketNumber}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need TicketNumber!");
      return;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db query
    my $SQL = "SELECT id FROM ticket " .
    " WHERE " .
    " tn = '$Param{TicketNumber}' ";
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        $Id = $Row[0];
    }
    return $Id;
}
# --

=item TicketNumberLookup()

ticket number lookup by ticket id

  my $TicketNumber = $TicketObject->TicketNumberLookup(
      TicketID => 123,
      UserID => 123,
  );

=cut

sub TicketNumberLookup {
    my $Self = shift;
    my %Param = @_;
    my $Tn = '';
    # check needed stuff
    if (!$Param{TicketID}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need TicketID!");
      return;
    }
    my %Ticket = $Self->TicketGet(%Param);
    if (%Ticket) {
        return $Ticket{TicketNumber};
    }
    else {
        return;
    }

}
# --

=item TicketGet() 

get ticket info (TicketNumber, State, StateID, Priority, PriorityID, 
Lock, LockID, Queue, QueueID, CustomerID, CustomerUserID, UserID, ...)

  my %Ticket = $TicketObject->TicketGet(
      TicketID => 123,
      UserID => 123,
  );

=cut

sub TicketGet {
    my $Self = shift;
    my %Param = @_;
    my %Ticket = ();
    # check needed stuff
    if (!$Param{TicketID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need TicketID!");
        return;
    }
    # check if result is cached 
    if ($Self->{'Cache::GetTicket'.$Param{TicketID}}) {
        return %{$Self->{'Cache::GetTicket'.$Param{TicketID}}};
    }
    # db query
    my $SQL = "SELECT st.id, st.queue_id, sq.name, st.ticket_state_id, slt.id, slt.name, ".
        " sp.id, sp.name, st.create_time_unix, st.create_time, sq.group_id, st.tn, ".
        " st.customer_id, st.user_id, su.$Self->{ConfigObject}->{DatabaseUserTableUserID}, ".
        " su.$Self->{ConfigObject}->{DatabaseUserTableUser}, st.ticket_answered, st.until_time, ".
        " st.customer_user_id, st.freekey1, st.freetext1, st.freekey2, st.freetext2,".
        " st.freekey3, st.freetext3, st.freekey4, st.freetext4,".
        " st.freekey5, st.freetext5, st.freekey6, st.freetext6,".
        " st.freekey7, st.freetext7, st.freekey8, st.freetext8 ".
        " FROM ".
        " ticket st, ticket_lock_type slt, ticket_priority sp, ".
        " queue sq, $Self->{ConfigObject}->{DatabaseUserTable} su ".
        " WHERE ".
        " slt.id = st.ticket_lock_id ".
        " AND ".
        " sp.id = st.ticket_priority_id ".
        " AND ".
        " sq.id = st.queue_id ".
        " AND ".
        " st.user_id = su.$Self->{ConfigObject}->{DatabaseUserTableUserID} ".
        " AND ".
        " st.id = ".$Self->{DBObject}->Quote($Param{TicketID})."";
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        $Ticket{TicketID} = $Row[0];
        $Ticket{QueueID} = $Row[1];
        $Ticket{Queue} = $Row[2];
        $Ticket{StateID} = $Row[3];
        $Ticket{LockID} = $Row[4];
        $Ticket{Lock} = $Row[5];
        $Ticket{PriorityID} = $Row[6];
        $Ticket{Priority} = $Row[7];
        $Ticket{Age} = $Self->{TimeObject}->SystemTime() - $Row[8];
        $Ticket{CreateTimeUnix} = $Row[8];
        $Ticket{Created} = $Self->{TimeObject}->SystemTime2TimeStamp(SystemTime => $Row[8]);
        $Ticket{GroupID} = $Row[10];
        $Ticket{TicketNumber} = $Row[11];
        $Ticket{CustomerID} = $Row[12];
        $Ticket{CustomerUserID} = $Row[18];
        $Ticket{UserID} = $Row[13];
        $Ticket{OwnerID} = $Row[14];
        $Ticket{Owner} = $Row[15];
        $Ticket{Answered} = $Row[16];
        $Ticket{RealTillTimeNotUsed} = $Row[17];
        $Ticket{TicketFreeKey1} = $Row[19] || '';
        $Ticket{TicketFreeText1} = $Row[20] || '';
        $Ticket{TicketFreeKey2} = $Row[21] || '';
        $Ticket{TicketFreeText2} = $Row[22] || '';
        $Ticket{TicketFreeKey3} = $Row[23] || '';
        $Ticket{TicketFreeText3} = $Row[24] || '';
        $Ticket{TicketFreeKey4} = $Row[25] || '';
        $Ticket{TicketFreeText4} = $Row[26] || '';
        $Ticket{TicketFreeKey5} = $Row[27] || '';
        $Ticket{TicketFreeText5} = $Row[28] || '';
        $Ticket{TicketFreeKey6} = $Row[29] || '';
        $Ticket{TicketFreeText6} = $Row[30] || '';
        $Ticket{TicketFreeKey7} = $Row[31] || '';
        $Ticket{TicketFreeText7} = $Row[32] || '';
        $Ticket{TicketFreeKey8} = $Row[33] || '';
        $Ticket{TicketFreeText8} = $Row[34] || '';
    }
    # check ticket
    if (!$Ticket{TicketID}) {
        $Self->{LogObject}->Log(
            Priority => 'error', 
            Message => "No such TicketID ($Param{TicketID})!",
        );
        return;
    }
    # get state info
    my %StateData = $Self->{StateObject}->StateGet(ID => $Ticket{StateID}, Cache => 1);
    $Ticket{StateType} = $StateData{TypeName};
    $Ticket{State} = $StateData{Name};
    if (!$Ticket{RealTillTimeNotUsed} || $StateData{TypeName} !~ /^pending/i) {
        $Ticket{UntilTime} = 0;
    }
    else {
        $Ticket{UntilTime} = $Ticket{RealTillTimeNotUsed} - $Self->{TimeObject}->SystemTime();
    }
    # cache user result
    $Self->{'Cache::GetTicket'.$Param{TicketID}} = \%Ticket;
    # return ticket data
    return %Ticket;
}
# --

=item TicketQueueID() 

get ticket queue id

  my $QueueID = $TicketObject->TicketQueueID(
      TicketID => 123,
  );

=cut

sub TicketQueueID {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{TicketID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need TicketID!");
        return;
    } 
    my %Ticket = $Self->TicketGet(%Param, UserID => 1);
    if (%Ticket) {
        return $Ticket{QueueID};
    }
    else {
        return;
    }
}
# --

=item MoveList()

to get the move queue list for a ticket (depends on workflow, if configured)

  my %Queues = $TicketObject->MoveList(
      Type => 'create',
      UserID => 123,
  );
    
  my %Queues = $TicketObject->MoveList(
      QueueID => 123,
      UserID => 123,
  );
    
  my %Queues = $TicketObject->MoveList(
      TicketID => 123,
      UserID => 123,
  );

=cut

sub MoveList {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{UserID} && !$Param{CustomerUserID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need UserID or CustomerUserID!");
        return;
    }
    # check needed stuff
    if (!$Param{QueueID} && !$Param{TicketID} && !$Param{Type}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need QueueID, TicketID or Type!");
        return;
    }
# TicketID!!!
    my %Queues = $Self->{QueueObject}->GetAllQueues(%Param);
#delete $Queues{315};
    # workflow
    if ($Self->TicketWorkflow(
        %Param,
        Type => 'Move',
        Data => \%Queues,
    )) { 
        return $Self->TicketWorkflowData();
    }
    # /workflow
    return %Queues;
}
# --

=item MoveTicket() 

to move a ticket (send notification to agentsw of selected my queues)

  $TicketObject->MoveList(
      QueueID => 123,
      TicketID => 123,
      UserID => 123,
  );

=cut

sub MoveTicket {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID QueueID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # move needed?
    if ($Param{QueueID} == $Self->TicketQueueID(TicketID => $Param{TicketID})) {
        # update not needed
        return 1;
    }
    # permission check
    my %MoveList = $Self->MoveList(%Param);
    if (!$MoveList{$Param{QueueID}}) {
        $Self->{LogObject}->Log(
            Priority => 'notice', 
            Message => "Permission denied on TicketID: $Param{TicketID}!",
        );
        return;
    }
    # remember to old queue
    my $OldQueueID = $Self->TicketQueueID(TicketID => $Param{TicketID});
    my $OldQueue = $Self->{QueueObject}->QueueLookup(QueueID => $OldQueueID);
    # db update
    my $SQL = "UPDATE ticket SET ".
      " queue_id = ".$Self->{DBObject}->Quote($Param{QueueID}).
      "  where id = ".$Self->{DBObject}->Quote($Param{TicketID})."";
    if ($Self->{DBObject}->Do(SQL => $SQL) ) {
        # queue lookup
        my $Queue = $Self->{QueueObject}->QueueLookup(QueueID => $Param{QueueID}); 
        # clear ticket cache
        $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
        # update ticket view index
        $Self->TicketAcceleratorUpdate(TicketID => $Param{TicketID});
        # history insert
        $Self->HistoryAdd(
            TicketID => $Param{TicketID},
            HistoryType => 'Move',
            Name => "\%\%$Queue\%\%$Param{QueueID}\%\%$OldQueue\%\%$OldQueueID",
            CreateUserID => $Param{UserID},
        );
        # send move notify to queue subscriber 
        foreach ($Self->{QueueObject}->GetAllUserIDsByQueueID(QueueID => $Param{QueueID})) {
            my %UserData = $Self->{UserObject}->GetUserData(UserID => $_);
            if ($UserData{UserSendMoveNotification}) {
                # send agent notification
                $Self->SendAgentNotification(
                    Type => 'Move',
                    UserData => \%UserData,
                    CustomerMessageParams => { Queue => $Queue },
                    TicketID => $Param{TicketID},
                    UserID => $Param{UserID},
                );
            }
        }
        # send customer notification email
        my %Preferences = $Self->{UserObject}->GetUserData(UserID => $Param{UserID});
        $Self->SendCustomerNotification(
            Type => 'QueueUpdate',
            CustomerMessageParams => { %Preferences, Queue => $Queue },
            TicketID => $Param{TicketID},
            UserID => $Param{UserID},
        ); 
        # should I unlock a ticket after move?
        if ($Self->{ConfigObject}->Get('Move::ForceUnlockAfterMove')) {
            $Self->LockSet(
                TicketID => $Param{TicketID},
                Lock => 'unlock',
                UserID => $Param{UserID},
            );
        }
        return 1;
    }
    else {
        return;
    }
}
# --
sub MoveQueueList {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db query
    my @Queue = ();
    my $SQL = "SELECT sh.name, ht.name, sh.create_by ".
        " FROM ".
        " ticket_history sh, ticket_history_type ht ".
        " WHERE ".
        " sh.ticket_id = $Param{TicketID} ".
        " AND ".
        " ht.name IN ('Move', 'NewTicket')  ".
        " AND ".
        " ht.id = sh.history_type_id".
        " ORDER BY sh.id";
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        # store result
        if ($Row[1] eq 'NewTicket') {
            if ($Row[2] ne '1') {
#                push (@Queue, $Row[2]);
            }
        }
        elsif ($Row[1] eq 'Move') {
            if ($Row[0] =~ /^Ticket moved to Queue '.+?' \(ID=(.+?)\)/) {
                push (@Queue, $1);
            }
        }
    }
    my @QueueInfo = ();
    foreach (@Queue) {
        # queue lookup
        my $Queue = $Self->{QueueObject}->QueueLookup(QueueID => $_, Cache => 1);
        push (@QueueInfo, $Queue);
    }
    return @Queue;
}
# --

=item SetCustomerData()

Set customer data of ticket.

  $TicketObject->SetCustomerData(
      No => 'client123',
      User => 'client-user-123',
      TicketID => 123,
      UserID => 23,
  );

=cut

sub SetCustomerData {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    if (!defined($Param{No}) && !defined($Param{User})) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need User or No for update!");
        return;
    }
    # clear ticket cache
    $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db customer id update
    if (defined($Param{No})) {
        $Param{No} = $Self->{DBObject}->Quote(lc($Param{No}));
        my $SQL = "UPDATE ticket SET customer_id = '$Param{No}', " .
          " change_time = current_timestamp, change_by = $Param{UserID} " .
          " WHERE id = $Param{TicketID} ";
        if ($Self->{DBObject}->Do(SQL => $SQL)) {
            $Param{History} = "CustomerID=$Param{No};";
        }
    }
    # db customer user update
    if (defined($Param{User})) {
        $Param{User} = $Self->{DBObject}->Quote(lc($Param{User}));
        my $SQL = "UPDATE ticket SET customer_user_id = '$Param{User}', " .
          " change_time = current_timestamp, change_by = $Param{UserID} " .
          " WHERE id = $Param{TicketID} ";
        if ($Self->{DBObject}->Do(SQL => $SQL)) {
            $Param{History} .= "CustomerUser=$Param{User};";
        }
    }
    if ($Param{History}) {
        # history insert
        $Self->HistoryAdd(
            TicketID => $Param{TicketID},
            HistoryType => 'CustomerUpdate',
            Name => "\%\%".$Param{History}, 
            CreateUserID => $Param{UserID},
        );
        return 1;
    }
    else {
        return;
    }
}
# --

=item TicketFreeTextGet()

get possible ticket free text options

  my $HashRef = $TicketObject->TicketFreeTextGet(
     Type => 'TicketFreeText3',
     TicketID => 123,
     UserID => 123,
  );

  my $HashRef = $TicketObject->TicketFreeTextGet(
     Type => 'TicketFreeText3',
     UserID => 123,
  );

=cut

sub TicketFreeTextGet {
    my $Self = shift;
    my %Param = @_;
    my $Value = $Param{Value} || '';
    my $Key = $Param{Key} || '';
    # check needed stuff
    foreach (qw(UserID Type)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    my %Data = ();
    if (ref($Self->{ConfigObject}->Get($Param{Type})) eq 'HASH') {
        %Data = %{$Self->{ConfigObject}->Get($Param{Type})};
    }
    # workflow
    if ($Self->TicketWorkflow(
        %Param,
        Type => $Param{Type},
        Data => \%Data,
    )) {
        my %Hash = $Self->TicketWorkflowData();
        return \%Hash;
    }
    # /workflow
    return $Self->{ConfigObject}->Get($Param{Type});
}
# --

=item TicketFreeTextSet()

Set ticket free text.

  $TicketObject->TicketFreeTextSet(
      Counter => 1,
      Key => 'Planet',
      Value => 'Sun',
      TicketID => 123,
      UserID => 23,
  );

=cut

sub TicketFreeTextSet {
    my $Self = shift;
    my %Param = @_;
    my $Value = $Param{Value} || '';
    my $Key = $Param{Key} || '';
    # check needed stuff
    foreach (qw(TicketID UserID Counter)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # check if update is needed
    my %Ticket = $Self->TicketGet(TicketID => $Param{TicketID});
    if ($Value eq $Ticket{"TicketFreeText$Param{Counter}"} && 
        $Key eq $Ticket{"TicketFreeKey$Param{Counter}"}) {
        return 1;
    }
    # clear ticket cache
    $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
    # db quote
    my $DBValue = $Self->{DBObject}->Quote($Value);
    my $DBKey = $Self->{DBObject}->Quote($Key);
    # db update
    my $SQL = "UPDATE ticket SET freekey$Param{Counter} = '$DBKey', " .
    " freetext$Param{Counter} = '$DBValue', " .
    " change_time = current_timestamp, change_by = $Param{UserID} " .
    " WHERE id = $Param{TicketID}";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
        # history insert
        $Self->HistoryAdd(
            TicketID => $Param{TicketID},
            HistoryType => 'TicketFreeTextUpdate',
            Name => "\%\%FreeKey$Param{Counter}\%\%$Key\%\%FreeText$Param{Counter}\%\%$Value", 
            CreateUserID => $Param{UserID},
        );
        return 1;
    }
    else {
        return;
    }
}
# --

=item TicketSetAnswered()

Set if ticket is answered.

  $TicketObject->TicketSetAnswered(TicketID => 123, UserID => 23);

=cut

sub TicketSetAnswered {
    my $Self = shift;
    my %Param = @_;
    my $Answered = $Param{Answered} || 0;
    # check needed stuff
    foreach (qw(TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # clear ticket cache
    $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db update
    my $SQL = "UPDATE ticket SET ticket_answered = $Answered, " .
    " change_time = current_timestamp, change_by = $Param{UserID} " .
    " WHERE id = $Param{TicketID} ";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
        return 1;
    }
    else {
        return;
    }
}
# --
sub Permission {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(Type TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    my $AccessOk = 0;
    # run all TicketPermission modules 
    if (ref($Self->{ConfigObject}->Get('Ticket::Permission')) eq 'HASH') { 
        my %Modules = %{$Self->{ConfigObject}->Get('Ticket::Permission')};
        foreach my $Module (sort keys %Modules) {
            # log try of load module
            if ($Self->{Debug} > 1) {
                $Self->{LogObject}->Log(
                    Priority => 'debug',
                    Message => "Try to load module: $Modules{$Module}->{Module}!",
                );
            }
            # load module
            if (eval "require $Modules{$Module}->{Module}") {
                # create object
                my $ModuleObject = $Modules{$Module}->{Module}->new(
                    ConfigObject => $Self->{ConfigObject},
                    LogObject => $Self->{LogObject},
                    DBObject => $Self->{DBObject},
                    TicketObject => $Self,
                    QueueObject => $Self->{QueueObject},
                    UserObject => $Self->{UserObject},
                    GroupObject => $Self->{GroupObject},
                    Debug => $Self->{Debug},
                );
                # execute Run()
                if ($ModuleObject->Run(%Param)) {
                    if ($Self->{Debug} > 0) {
                      $Self->{LogObject}->Log(
                        Priority => 'debug',
                        Message => "Got '$Param{Type}' true for TicketID '$Param{TicketID}' ".
                            "through $Modules{$Module}->{Module}!",
                      );
                    }
                    # set access ok
                    $AccessOk = 1;
                    # check granted option (should I say ok)
                    if ($Modules{$Module}->{Granted}) {
                        if ($Self->{Debug} > 0) {
                          $Self->{LogObject}->Log(
                            Priority => 'debug',
                            Message => "Granted access '$Param{Type}' true for TicketID '$Param{TicketID}' ".
                                "through $Modules{$Module}->{Module} (no more checks)!",
                          );
                        }
                        # access ok
                        return 1;
                    }
                }
                else {
                    # return because true is required
                    if ($Modules{$Module}->{Required}) {
                        $Self->{LogObject}->Log(
                            Priority => 'notice', 
                            Message => "Permission denied because module ".
                             "($Modules{$Module}->{Module}) is required ".
                             "(UserID: $Param{UserID} '$Param{Type}' on ".
                             "TicketID: $Param{TicketID})!",
                        );
                        return;
                    }
                }
            }
            else {
                $Self->{LogObject}->Log(
                    Priority => 'error',
                    Message => "Can't load module $Modules{$Module}->{Module}!",
                );
            }
        }
    }
    # grant access to the ticket
    if ($AccessOk) {
        return 1;
    }
    # don't grant access to the ticket
    else {
        $Self->{LogObject}->Log(
            Priority => 'notice', 
            Message => "Permission denied (UserID: $Param{UserID} '$Param{Type}' on TicketID: $Param{TicketID})!",
        );
        return;
    }
}
# --
sub CustomerPermission {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(Type TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # run all CustomerTicketPermission modules 
    my $AccessOk = 0;
    if (ref($Self->{ConfigObject}->Get('CustomerTicket::Permission')) eq 'HASH') { 
        my %Modules = %{$Self->{ConfigObject}->Get('CustomerTicket::Permission')};
        foreach my $Module (sort keys %Modules) {
            # log try of load module
            if ($Self->{Debug} > 1) {
                $Self->{LogObject}->Log(
                    Priority => 'debug',
                    Message => "Try to load module: $Modules{$Module}->{Module}!",
                );
            }
            # load module
            if (eval "require $Modules{$Module}->{Module}") {
                # create object
                my $ModuleObject = $Modules{$Module}->{Module}->new(
                    ConfigObject => $Self->{ConfigObject},
                    LogObject => $Self->{LogObject},
                    DBObject => $Self->{DBObject},
                    TicketObject => $Self,
                    QueueObject => $Self->{QueueObject},
                    CustomerUserObject => $Self->{CustomerUserObject},
                    CustomerGroupObject => $Self->{CustomerGroupObject},
                    Debug => $Self->{Debug},
                );
                # execute Run()
                if ($ModuleObject->Run(%Param)) {
                    if ($Self->{Debug} > 0) {
                      $Self->{LogObject}->Log(
                        Priority => 'debug',
                        Message => "Got '$Param{Type}' true for TicketID '$Param{TicketID}' ".
                            "through $Modules{$Module}->{Module}!",
                      );
                    }
                    # set access ok
                    $AccessOk = 1;
                    # check granted option (should I say ok)
                    if ($Modules{$Module}->{Granted}) {
                        if ($Self->{Debug} > 0) {
                          $Self->{LogObject}->Log(
                            Priority => 'debug',
                            Message => "Granted access '$Param{Type}' true for TicketID '$Param{TicketID}' ".
                                "through $Modules{$Module}->{Module} (no more checks)!",
                          );
                        }
                        # access ok
                        return 1;
                    }
                }
                else {
                    # return because true is required
                    if ($Modules{$Module}->{Required}) {
                        $Self->{LogObject}->Log(
                            Priority => 'notice', 
                            Message => "Permission denied because module ".
                             "($Modules{$Module}->{Module}) is required ".
                             "(UserID: $Param{UserID} '$Param{Type}' on ".
                             "TicketID: $Param{TicketID})!",
                        );
                        return;
                    }
                }
            }
            else {
                $Self->{LogObject}->Log(
                    Priority => 'error',
                    Message => "Can't load module $Modules{$Module}->{Module}!",
                );
            }
        }
    }
    # grant access to the ticket
    if ($AccessOk) {
        return 1;
    }
    # don't grant access to the ticket
    else {
        $Self->{LogObject}->Log(
            Priority => 'notice', 
            Message => "Permission denied (UserID: $Param{UserID} '$Param{Type}' on TicketID: $Param{TicketID})!",
        );
        return;
    }
}
# --

=item GetLockedTicketIDs()

Get locked ticket ids for an agent.

  my @TicketIDs = $TicketObject->GetLockedTicketIDs(UserID => 23);

=cut

sub GetLockedTicketIDs {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{UserID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need UserID!");
        return;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    my @ViewableTickets;
    my @ViewableLocks = @{$Self->{ConfigObject}->Get('ViewableLocks')};
    my $SQL = "SELECT ti.id " .
      " FROM " .
      " ticket ti, ticket_lock_type slt, queue sq" .
      " WHERE " .
      " ti.user_id = $Param{UserID} " .
      " AND ".
      " slt.id = ti.ticket_lock_id " .
      " AND ".
      " sq.id = ti.queue_id".
      " AND ".
      " slt.name not in ( ${\(join ', ', @ViewableLocks)} ) ORDER BY ";
    # sort by
    if (!$Param{SortBy} || $Param{SortBy} =~ /^CreateTime$/i) {
        $SQL .= "ti.create_time";
    }
    elsif ($Param{SortBy} =~ /^Queue$/i) {
        $SQL .= " sq.name";
    }
    elsif ($Param{SortBy} =~ /^CustomerID$/i) {
        $SQL .= " ti.customer_id";
    }
    elsif ($Param{SortBy} =~ /^Priority$/i) {
        $SQL .= " ti.ticket_priority_id";
    }
    else {
        $SQL .= "ti.create_time";
    }
    # order
    if ($Param{OrderBy} && $Param{OrderBy} eq 'Down') {
        $SQL .= " DESC";
    }
    else {
        $SQL .= " ASC";
    }

    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @RowTmp = $Self->{DBObject}->FetchrowArray()) {
        push (@ViewableTickets, $RowTmp[0]);
    }
    return @ViewableTickets;
}
# --
sub GetCustomerTickets {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{CustomerUserID} && !$Param{UserID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need CustomerUserID or UserID!");
        return;
    }
    if (!$Param{CustomerUserID} && !$Param{CustomerID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need CustomerUserID or CustomerID!");
        return;
    }
    # get closed tickets
    my $SQLExt = '';
    if ($Param{ShowJustOpenTickets}) {
        my @ViewableStateIDs = $Self->{StateObject}->StateGetStatesByType(
            Type => 'Viewable',
            Result => 'ID',
        );
        $SQLExt .= " AND ";
        $SQLExt .= " st.ticket_state_id in ( ${\(join ', ', @ViewableStateIDs)} ) ";
    }
    # get group permissions
    my @GroupIDs = ();
    if ($Param{CustomerUserID}) {
        @GroupIDs = $Self->{CustomerGroupObject}->GroupMemberList(
            UserID => $Param{CustomerUserID},
            Type => 'ro',
            Result => 'ID',
            Cached => 1,
        );
    }
    else {
        @GroupIDs = $Self->{GroupObject}->GroupMemberList(
            UserID => $Param{UserID},
            Type => 'ro',
            Result => 'ID',
            Cached => 1,
        );
    }
    # order by
    my $OrderSQL = '';
    if ($Param{SortBy} && $Param{SortBy} eq 'Owner') {
        $OrderSQL .= "u.".$Self->{ConfigObject}->Get('DatabaseUserTableUser');
    }
    elsif ($Param{SortBy} && $Param{SortBy} eq 'CustomerID') {
        $OrderSQL .= "st.customer_id";
    }
    elsif ($Param{SortBy} && $Param{SortBy} eq 'State') {
        $OrderSQL .= "tsd.name";
    }
    elsif ($Param{SortBy} && $Param{SortBy} eq 'Ticket') {
        $OrderSQL .= "st.tn";
    }
    elsif ($Param{SortBy} && $Param{SortBy} eq 'Queue') {
        $OrderSQL .= "q.name";
    }
    else {
        $OrderSQL .= "st.create_time_unix";
    }
    # sort by 
    if ($Param{SortBy} && $Param{SortBy} eq 'Age') {
        if ($Param{Order} && $Param{Order} eq 'Down') {
            $OrderSQL .= " ASC";
        }
        else {
            $OrderSQL .= " DESC";
        }
    }
    else {
        if ($Param{Order}  && $Param{Order} eq 'Down') {
            $OrderSQL .= " DESC";
        }
        else {
            $OrderSQL .= " ASC";
        }
    }

    my @TicketIDs = ();
    my $SQL = "SELECT st.id, st.tn ".
        " FROM ".
        " ticket st, queue q, ticket_state tsd,  ".
        $Self->{ConfigObject}->Get('DatabaseUserTable')." u ".
        " WHERE ".
        " st.queue_id = q.id ".
        " AND ".
        " tsd.id = st.ticket_state_id ".
        " AND " .
        " st.user_id = u.".$Self->{ConfigObject}->Get('DatabaseUserTableUserID').
        " AND ";
    if ($Param{Type} && $Param{Type} eq 'MyTickets') {
        $SQL .= " st.customer_user_id = '".$Self->{DBObject}->Quote($Param{CustomerUserID})."' ";
    }
    else {
        $SQL .= " st.customer_id = '".$Self->{DBObject}->Quote($Param{CustomerID})."' ";
    }
    $SQL .= " AND ".
        " q.group_id IN ( ${\(join ', ', @GroupIDs)} ) ".
        $SQLExt." ORDER BY ".$OrderSQL;
    $Self->{DBObject}->Prepare(SQL => $SQL, Limit => $Param{Limit} || 60);
    while (my @Row = $Self->{DBObject}->FetchrowArray() ) {
        push(@TicketIDs, $Row[0]);
    }
    return @TicketIDs;
}
# --

=item TicketPendingTimeSet()

set ticket pending time

  $TicketObject->TicketPendingTimeSet(
      Year => 2003,
      Month => 08,
      Day => 14,
      Hour => 22,
      Minute => 05,
      TicketID => 123,
      UserID => 23,
  );

=cut

sub TicketPendingTimeSet {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(Year Month Day Hour Minute TicketID UserID)) {
      if (!defined($Param{$_})) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    my $time = timelocal(1,$Param{Minute},$Param{Hour},$Param{Day},($Param{Month}-1),$Param{Year});
    # clear ticket cache
    $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db update
    my $SQL = "UPDATE ticket SET until_time = $time, " .
    " change_time = current_timestamp, change_by = $Param{UserID} " .
    " WHERE id = $Param{TicketID} ";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
        # history insert
        $Self->HistoryAdd(
            TicketID => $Param{TicketID},
            HistoryType => 'SetPendingTime',
            Name => '%%'.sprintf("%02d", $Param{Year}).
              '-'.sprintf("%02d", $Param{Month}).'-'.sprintf("%02d", $Param{Day}).' '.
              sprintf("%02d", $Param{Hour}).':'.sprintf("%02d", $Param{Minute}).'',
            CreateUserID => $Param{UserID},
        );
        return 1;
    }
    else {
        return;
    }
}
# --

=item TicketLinkGet()

Get ticket links.

  $TicketObject->TicketLinkGet(
      TicketID => 1422,
      UserID => 23,
  );

=cut

sub TicketLinkGet {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_}) || '';
    }
    # db query
    my %Tickets = ();
    my %Used = ();
    my $Counter = 0;
    my $SQL = "SELECT st.id, st.tn ".
        " FROM ".
        " ticket st, ticket_link tl ".
        " WHERE ".
        " (st.id = tl.ticket_id_master OR st.id = tl.ticket_id_slave) ".
        " AND ".
        " (tl.ticket_id_master = $Param{TicketID} OR tl.ticket_id_slave = $Param{TicketID})";
    $Self->{DBObject}->Prepare(SQL => $SQL, Limit => 60);
    while (my @Row = $Self->{DBObject}->FetchrowArray() ) {
        if (!$Used{$Row[0]}) {
            if ($Row[0] ne $Param{TicketID}) {
                $Counter++;
                $Tickets{"TicketLink$Counter"} = $Row[1];
                $Tickets{"TicketLinkID$Counter"} = $Row[0];
                $Used{$Row[0]} = 1;
            }
        }
    }
    return %Tickets;
}
# --

=item TicketLinkAdd()

Add a ticket link.

  $TicketObject->TicketLinkAdd(
      MasterTicketID => 3541,
      SlaveTicketID => 1422,
      UserID => 23,
  );

=cut

sub TicketLinkAdd {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(MasterTicketID SlaveTicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_}) || '';
    }
    # create db record
    my $SQL = "INSERT INTO ticket_link (ticket_id_master, ticket_id_slave) ".
    " VALUES ($Param{MasterTicketID}, $Param{SlaveTicketID}) ";
        
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
        return 1;
    }
    else {
        return;
    }
}
# --

=item TicketLinkDelete()

Delete a ticket link.

  $TicketObject->TicketLinkDelete(
      MasterTicketID => 3541,
      SlaveTicketID => 1422,
      UserID => 23,
  );

=cut

sub TicketLinkDelete {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(MasterTicketID SlaveTicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_}) || '';
    }
    # db query
    my $SQL = "DELETE FROM ticket_link ".
        " WHERE ".
        " ticket_id_master = $Param{MasterTicketID} ".
        " AND ".
        " ticket_id_slave = $Param{SlaveTicketID} ".
        " ";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
        return 1;
    }
    else {
        return;
    }
}
# --

=item TicketSearch()

To find tickets in your system.
  
  my @TicketIDs = $TicketObject->TicketSearch(
      # result (required)
      Result => 'ARRAY' || 'HASH',

      # ticket properties (optional)
      Queue => 'system queue',
      States => ['new', 'open'],
      StateIDs => [3, 4],
      Priorities => ['1 very low', '2 low', '3 normal'],
      PriorityIDs => [1, 2, 3],
      Locks => ['unlock'],
      UserIDs => [1, 12, 455, 32]
      Owner => '123',
      CustomerID => '123',
      CustomerUserLogin => 'uid123',

      # 1..8 (optional)
      TicketFreeKey1 => 'Product',
      TicketFreeText1 => 'adasd',
      # or with multi options as array ref
      TicketFreeKey2 => ['Product', 'Product2'],
      TicketFreeText2 => ['Browser', 'Sound', 'Mouse'],

      # article stuff (optional)
      From => '%spam@example.com%',
      To => '%support@example.com%',
      Cc => '%client@example.com%',
      Subject => '%VIRUS 32%',
      Body => '%VIRUS 32%', 

      # tickets older the 60 minutes (optional)
      TicketCreateTimeOlderMinutes => 60,
      # tickets newer then 60 minutes (optional)
      TicketCreateTimeNewerMinutes => 60,

      # tickets with create time older then .... (optional)
      TicketCreateTimeOlderDate => '2004-01-19 00:00:01',
      # tickets with create time newer then ... (optional)
      TicketCreateTimeNewerDate => '2004-01-09 23:59:59',

      # search user (optional)
      UserID => 123,
      Permission => 'ro' || 'rw', 
  );

=cut

sub TicketSearch {
    my $Self = shift;
    my %Param = @_;
    my $Result = $Param{Result} || 'HASH';
    my $OrderBy = $Param{OrderBy} || 'Down';
    my $SortBy = $Param{SortBy} || 'Age';
    my $Limit = $Param{Limit} || 10000;
    my %SortOptions = (
        Owner => 'st.user_id',
        CustomerID => 'st.customer_id',
        State => 'st.ticket_state_id', 
        Ticket => 'st.tn',
        Queue => 'sq.name', 
        Priority => 'st.ticket_priority_id', 
        Age => 'st.create_time_unix',
    );
    # check options
    if (!$SortOptions{$SortBy}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need valid SortBy!");
        return;
    }
    if ($OrderBy ne 'Down' && $OrderBy ne 'Up') {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need valid OrderBy!");
        return;
    }
    # sql
    my $SQLExt = '';
    my $SQL = "SELECT DISTINCT st.id, st.tn, $SortOptions{$SortBy} FROM ".
    " ticket st, queue sq ";
    # use also article table it required
    my $UseArticleTable = 0;
    foreach (qw(From To Cc Subject Body)) {
        if ($Param{$_} && !$UseArticleTable) {
            $SQL .= ", article at ";
            $UseArticleTable = 1;
        }
    }
    $SQL .= " WHERE sq.id = st.queue_id";
    
    # if article table used
    if ($UseArticleTable) {
        $SQLExt .= " AND st.id = at.ticket_id";
    }
    # ticket states
    if ($Param{States}) {
        foreach (@{$Param{States}}) {
            my %State = $Self->{StateObject}->StateGet(Name => $_, Cache => 1);
            if ($State{ID}) {
                push (@{$Param{StateIDs}}, $State{ID}); 
            }
            else {
                return;
            }
        }
    }
    if ($Param{StateIDs}) {
        $SQLExt .= " AND st.ticket_state_id IN (${\(join ', ' , @{$Param{StateIDs}})})";
    }
    # ticket locks
    if ($Param{Locks}) {
        foreach (@{$Param{Locks}}) {
            if ($Self->{LockObject}->LockLookup(Type => $_)) {
                push (@{$Param{LockIDs}}, $Self->{LockObject}->LockLookup(Type => $_)); 
            }
            else {
                return;
            }
        }
    } 
    # add lock ids
    if ($Param{LockIDs}) {
        $SQLExt .= " AND st.ticket_lock_id IN (${\(join ', ' , @{$Param{LockIDs}})})";
    }
    # add user ids
    if ($Param{UserIDs}) {
        $SQLExt .= " AND st.user_id IN (${\(join ', ' , @{$Param{UserIDs}})})";
    }
    # ticket queues
    if ($Param{Queues}) {
        foreach (@{$Param{Queues}}) {
            if ($Self->{QueueObject}->QueueLookup(Queue => $_)) {
                push (@{$Param{QueueIDs}}, $Self->{QueueObject}->QueueLookup(Queue => $_));
            }
            else {
                return;
            }
        }
    }
    if ($Param{QueueIDs}) {
        $SQLExt .= " AND st.queue_id IN (${\(join ', ' , @{$Param{QueueIDs}})})";
    }
    # user groups
    if ($Param{UserID}) {
        # get users groups
        my @GroupIDs = $Self->{GroupObject}->GroupMemberList(
            UserID => $Param{UserID},
            Type => $Param{Permission} || 'ro',
            Result => 'ID',
            Cached => 1,
        );
        if (@GroupIDs) {
            $SQLExt .= " AND sq.group_id IN (${\(join ', ' , @GroupIDs)}) ";
        }
        else {
            return;
        }
    }
    # ticket number
    if ($Param{TicketNumber}) {
        my $TicketNumber = $Param{TicketNumber};
        $TicketNumber =~ s/\*/%/gi;
        $SQLExt .= " AND st.tn LIKE '".$Self->{DBObject}->Quote($TicketNumber)."'";
    }
    # ticket priorities 
    if ($Param{Priorities}) {
        foreach (@{$Param{Priorities}}) {
            my $ID = $Self->PriorityLookup(Type => $_);
            if ($ID) {
                push (@{$Param{PriorityIDs}}, $ID);
            }
            else {
                return;
            }
        }
    }
    if ($Param{PriorityIDs}) {
        $SQLExt .= " AND st.ticket_priority_id IN (${\(join ', ' , @{$Param{PriorityIDs}})})";
    }
    # other ticket stuff 
    my %FieldSQLMap = (
        CustomerID => 'st.customer_id',
        CustomerUserLogin => 'st.customer_user_id',
    );
    foreach my $Key (keys %FieldSQLMap) {
        if ($Param{$Key}) {
            $Param{$Key} =~ s/\*/%/gi;
                $SQLExt .= " AND $FieldSQLMap{$Key} LIKE '".$Self->{DBObject}->Quote($Param{$Key})."'";
        }
    }
    # article stuff
    my %FieldSQLMapFullText = (
        From => 'at.a_from',
        To => 'at.a_to',
        Cc => 'at.a_cc',
        Subject => 'at.a_subject',
        Body => 'at.a_body',
    );
    foreach my $Key (keys %FieldSQLMapFullText) {
        if ($Param{$Key}) {
            $Param{$Key} =~ s/\*/%/gi;
            $SQLExt .= " AND $FieldSQLMapFullText{$Key} LIKE '".$Self->{DBObject}->Quote($Param{$Key})."'";
        }
    }
    # ticket free text
    foreach (1..8) {
        if ($Param{"TicketFreeKey$_"} && ref($Param{"TicketFreeKey$_"}) eq 'SCALAR') {
            $Param{"TicketFreeKey$_"} =~ s/\*/%/gi;
            $SQLExt .= " AND st.freekey$_ LIKE '".$Self->{DBObject}->Quote($Param{"TicketFreeKey$_"})."'";
        }
        elsif ($Param{"TicketFreeKey$_"} && ref($Param{"TicketFreeKey$_"}) eq 'ARRAY') { 
            my $SQLExtSub = ' AND (';
            my $Counter = 0;
            foreach my $Key (@{$Param{"TicketFreeKey$_"}}) {
                if (defined($Key ) && $Key ne '') {
                    $Key =~ s/\*/%/gi; 
                    $SQLExtSub .= ' OR ' if ($Counter);
                    $SQLExtSub .= " st.freekey$_ LIKE '".$Self->{DBObject}->Quote($Key)."'";
                    $Counter++;
                }
            }
            $SQLExtSub .= ')';
            if ($Counter) {
                $SQLExt .= $SQLExtSub;
            }
        }
    }
    foreach (1..8) {
        if ($Param{"TicketFreeText$_"} && ref($Param{"TicketFreeText$_"}) eq 'SCALAR') {
            $Param{"TicketFreeText$_"} =~ s/\*/%/gi;
            $SQLExt .= " AND st.freetext$_ LIKE '".$Self->{DBObject}->Quote($Param{"TicketFreeText$_"})."'";
        }
        elsif ($Param{"TicketFreeText$_"} && ref($Param{"TicketFreeText$_"}) eq 'ARRAY') { 
            my $SQLExtSub = ' AND (';
            my $Counter = 0;
            foreach my $Text (@{$Param{"TicketFreeText$_"}}) {
                if (defined($Text) && $Text ne '') {
                    $Text =~ s/\*/%/gi; 
                    $SQLExtSub .= ' OR ' if ($Counter);
                    $SQLExtSub .= " st.freetext$_ LIKE '".$Self->{DBObject}->Quote($Text)."'";
                    $Counter++;
                }
            }
            $SQLExtSub .= ')';
            if ($Counter) {
                $SQLExt .= $SQLExtSub;
            }
        }
    }
    # get tickets older then x minutes
    if ($Param{TicketCreateTimeOlderMinutes}) {
        my $Time = $Self->{TimeObject}->SystemTime()-($Param{TicketCreateTimeOlderMinutes}*60);
        $SQLExt .= " AND st.create_time_unix <= ".$Self->{DBObject}->Quote($Time);
    }
    # get tickets newer then x minutes
    if ($Param{TicketCreateTimeNewerMinutes}) {
        my $Time = $Self->{TimeObject}->SystemTime()-($Param{TicketCreateTimeNewerMinutes}*60);
        $SQLExt .= " AND st.create_time_unix >= ".$Self->{DBObject}->Quote($Time);
    }
    # get tickets older then xxxx-xx-xx xx:xx date 
    if ($Param{TicketCreateTimeOlderDate}) {
        # check time format
        if ($Param{TicketCreateTimeOlderDate} !~ /\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d/) {
            $Self->{LogObject}->Log( 
                Priority => 'error',  
                Message => "No valid time format '$Param{TicketCreateTimeOlderDate}'!",
            );
            return;
        }
        else {
            $SQLExt .= " AND st.create_time <= '".$Self->{DBObject}->Quote($Param{TicketCreateTimeOlderDate})."'";
        }
    }
    # get tickets newer then xxxx-xx-xx xx:xx date 
    if ($Param{TicketCreateTimeNewerDate}) {
        if ($Param{TicketCreateTimeNewerDate} !~ /\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d/) {
            $Self->{LogObject}->Log( 
                Priority => 'error',  
                Message => "No valid time format '$Param{TicketCreateTimeNewerDate}'!",
            );
            return;
        }
        else {
            $SQLExt .= " AND st.create_time >= '".$Self->{DBObject}->Quote($Param{TicketCreateTimeNewerDate})."'";
        }
    }
    # database query
    $SQLExt .= " ORDER BY $SortOptions{$SortBy}";
    if ($OrderBy eq 'Up') {
        $SQLExt .= ' ASC';
    }
    else {
        $SQLExt .= ' DESC';
    }
    my %Tickets = ();
    my @TicketIDs = ();
    $Self->{DBObject}->Prepare(SQL => $SQL.$SQLExt, Limit => $Limit);
#print STDERR "SQL: $SQL$SQLExt\n";
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        $Tickets{$Row[0]} = $Row[1];
        push (@TicketIDs, $Row[0]);
    }
    if ($Result eq 'HASH') {
        return %Tickets;
    }
    else {
        return @TicketIDs;
    }
}
# --

=item LockIsTicketLocked()

check if a ticket is locked or not

  if ($TicketObject->LockIsTicketLocked(TicketID => 123)) {
      print "Ticket not locked!\n";
  }
  else {
      print "Ticket is not locked!\n";
  }

=cut

sub LockIsTicketLocked {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{TicketID}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need TicketID!");
      return;
    }
    my %TicketData = $Self->TicketGet(%Param);
    # check lock state
    if ($TicketData{Lock} =~ /^lock$/i) {
        return 1;
    }
    else {
        return;
    }
}
# --

=item LockSet()

to set a ticket lock or unlock

  $TicketObject->LockSet(
      Lock => 'lock',
      TicketID => 123,
      UserID => 123,
  );

=cut

# --
sub LockSet {
    my $Self = shift;
    my %Param = @_;
    # lookup!
    if ((!$Param{LockID}) && ($Param{Lock})) {
        $Param{LockID} = $Self->{LockObject}->LockLookup(Type => $Param{Lock});
    }
    # check needed stuff
    foreach (qw(TicketID UserID LockID Lock)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    if (!$Param{Lock} && !$Param{LockID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need LockID or Lock!");
        return;
    }
    # check if update is needed
    if (($Self->LockIsTicketLocked(TicketID => $Param{TicketID}) && $Param{Lock} eq 'lock') ||
        (!$Self->LockIsTicketLocked(TicketID => $Param{TicketID}) && $Param{Lock} eq 'unlock')) {
        # update not needed
        return 1;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db update
    my $SQL = "UPDATE ticket SET ticket_lock_id = $Param{LockID}, " .
    " change_time = current_timestamp, change_by = $Param{UserID} " .
        " WHERE id = $Param{TicketID}";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
      # clear ticket cache
      $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
      # update ticket view index
      $Self->TicketAcceleratorUpdate(TicketID => $Param{TicketID});
      # set lock time it event is 'lock'
      if ($Param{Lock} eq 'lock') {
        $SQL = "UPDATE ticket SET timeout = ".$Self->{TimeObject}->SystemTime(). 
          " WHERE id = $Param{TicketID} "; 
        $Self->{DBObject}->Do(SQL => $SQL);
      }
      # add history
      my $HistoryType = '';
      if ($Param{Lock} =~ /^unlock$/i) {
        $HistoryType = 'Unlock';
      }
      elsif ($Param{Lock} =~ /^lock$/i) {
        $HistoryType = 'Lock';
      }
      else {
        $HistoryType = 'Misc';
      }

      if ($HistoryType) {
        $Self->HistoryAdd(
          TicketID => $Param{TicketID},
          CreateUserID => $Param{UserID},
          HistoryType => $HistoryType,
          Name => "\%\%$Param{Lock}",
        );
      }

      # send unlock notify
      if ($Param{Lock} =~ /^unlock$/i) {
          my %TicketData = $Self->TicketGet(%Param);
          # check if the current user is the current owner, if not send a notify
          my $To = '';
          my $Notification = defined $Param{Notification} ? $Param{Notification} : 1;
          if ($TicketData{UserID} ne $Param{UserID} && $Notification) {
              # get user data of owner
              my %Preferences = $Self->{UserObject}->GetUserData(UserID => $TicketData{UserID});
              if ($Preferences{UserSendLockTimeoutNotification}) {
                  # send
                  $Self->SendAgentNotification(
                      Type => 'LockTimeout',
                      UserData => \%Preferences,
                      CustomerMessageParams => {}, 
                      TicketID => $Param{TicketID},
                      UserID => $Param{UserID},
                  );
              }
          }
      }
      # should I unlock a ticket after move?
      if ($Param{Lock} =~ /^lock$/i) {
          if ($Self->{ConfigObject}->Get('Lock::ForceNewStateAfterLock')) {
            my %States = %{$Self->{ConfigObject}->Get('Lock::ForceNewStateAfterLock')};
            my %Ticket = $Self->TicketGet(%Param); 
            foreach (keys %States) {
              if ($_ eq $Ticket{State} && $States{$_}) {
                  $Self->StateSet(%Param, State => $States{$_});
              }
            }
          }
      }
      return 1;
    }
    else {
      return;
    }
}
# --

=item StateSet()
    
to set a ticket state 

  $TicketObject->SateSet(
      State => 'open',
      TicketID => 123,
      UserID => 123,
  );

  $TicketObject->SateSet(
      StateID => 3,
      TicketID => 123,
      UserID => 123,
  );

=cut

sub StateSet {
    my $Self = shift;
    my %Param = @_;
    my $ArticleID = $Param{ArticleID} || '';
    # check needed stuff
    foreach (qw(TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    if (!$Param{State} && !$Param{StateID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need StateID or State!");
        return;
    }
    # state id lookup
    if (!$Param{StateID}) {
        my %State = $Self->{StateObject}->StateGet(Name => $Param{State}, Cache => 1);
        $Param{StateID} = $State{ID} || return;
    }
    # state lookup
    if (!$Param{State}) {
        my %State = $Self->{StateObject}->StateGet(ID => $Param{StateID}, Cache => 1);
        $Param{State} = $State{Name} || return;
    } 
    # check if update is needed
    my %Ticket = $Self->TicketGet(TicketID => $Param{TicketID});
    if ($Param{State} eq $Ticket{State}) {
      # update is not needed
      return 1;
    }
    # permission check
    my %StateList = $Self->StateList(%Param);
    if (!$StateList{$Param{StateID}}) {
        $Self->{LogObject}->Log(
            Priority => 'notice', 
            Message => "Permission denied on TicketID: $Param{TicketID}!",
        );
        return;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db update
    my $SQL = "UPDATE ticket SET ticket_state_id = $Param{StateID}, " .
    " change_time = current_timestamp, change_by = $Param{UserID} " .
    " WHERE id = $Param{TicketID} ";

    if ($Self->{DBObject}->Do(SQL => $SQL)) {
      # clear ticket cache
      $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
      # update ticket view index
      $Self->TicketAcceleratorUpdate(TicketID => $Param{TicketID});
      # add history
      $Self->HistoryAdd(
          TicketID => $Param{TicketID},
          ArticleID => $ArticleID,
          HistoryType => 'StateUpdate',
          Name => "\%\%$Ticket{State}\%\%$Param{State}",
          CreateUserID => $Param{UserID},
      );
      # send customer notification email
      $Self->SendCustomerNotification(
          Type => 'StateUpdate',
		  CustomerMessageParams => \%Param,
          TicketID => $Param{TicketID},
          UserID => $Param{UserID},
      );
      return 1;
    }
    else {
      return;
    }
}
# --

=item StateList()

to get the state list for a ticket (depends on workflow, if configured)

  my %States = $TicketObject->StateList(
      TicketID => 123,
      UserID => 123,
  );

  my %States = $TicketObject->StateList(
      QueueID => 123,
      UserID => 123,
  );

  my %States = $TicketObject->StateList(
      TicketID => 123,
      Type => 'open',
      UserID => 123,
  );

=cut

sub StateList {
    my $Self = shift;
    my %Param = @_;
    my %States = ();
    # check needed stuff
    if (!$Param{UserID} && !$Param{CustomerUserID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need UserID or CustomerUserID!");
        return;
    }
    # check needed stuff
    if (!$Param{QueueID} && !$Param{TicketID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need QueueID, TicketID!");
        return;
    }
    # check needed stuff
    if (!$Param{Type}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need Type!");
        return;
    }
    # get states by type
    if ($Param{Type}) {
        %States = $Self->{StateObject}->StateGetStatesByType(
            Type => $Param{Type}, 
            Result => 'HASH',
        );
    }
#delete $States{4}; # remove open!
    # workflow
    if ($Self->TicketWorkflow(
        %Param,
        Type => 'State',
        Data => \%States,
    )) { 
        return $Self->TicketWorkflowData();
    }
    # /workflow
    return %States;
}
# --

=item OwnerCheck()
    
to get the ticket owner

  my ($OwnerID, $Owner) = $TicketObject->OwnerCheck(TicketID => 123);

=cut

sub OwnerCheck {
    my $Self = shift;
    my %Param = @_;
    my $SQL = '';
    # check needed stuff
    if (!$Param{TicketID}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need TicketID!");
      return;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db query
    if ($Param{UserID}) {
        $SQL = "SELECT user_id, user_id " .
        " FROM " .
        " ticket " .
        " WHERE " .
        " id = $Param{TicketID} " .
        " AND " .
        " user_id = $Param{UserID}";
    }
    else {
        $SQL = "SELECT st.user_id, su.$Self->{ConfigObject}->{DatabaseUserTableUser} " .
        " FROM " .
        " ticket st, $Self->{ConfigObject}->{DatabaseUserTable} su " .
        " WHERE " .
        " st.id = $Param{TicketID} " .
        " AND " .
        " st.user_id = su.$Self->{ConfigObject}->{DatabaseUserTableUserID}";
    }
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        $Param{SearchUserID} = $Row[0];
        $Param{SearchUser} = $Row[1];
    }
    if ($Param{SearchUserID}) {
      return $Param{SearchUserID}, $Param{SearchUser};
    } 
    else {
      return;
    }
}
# --

=item OwnerSet()

to set the ticket owner (notification to the new owner will be sent)

  $TicketObject->OwnerSet(
      TicketID => 123,
      NewUserID => 555,
      UserID => 213,
  );

=cut

sub OwnerSet {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    if (!$Param{NewUserID} && !$Param{NewUser}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need NewUserID or NewUser!");
        return;
    }
    # lookup if no NewUserID is given
    if (!$Param{NewUserID}) {
      $Param{NewUserID} = $Self->{UserObject}->GetUserIdByName(User => $Param{NewUser})||return;
    }
    # lookup if no NewUser is given
    if (!$Param{NewUser}) {
      $Param{NewUser} = $Self->{UserObject}->GetUserByID(UserID => $Param{NewUserID})||return;
    }
    # check if update is needed!
    if ($Self->OwnerCheck(TicketID => $Param{TicketID}, UserID => $Param{NewUserID})) {
        # update is "not" needed!
        return 1;
    }
    # clear ticket cache
    $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db update
    my $SQL = "UPDATE ticket SET user_id = $Param{NewUserID}, " .
    " change_time = current_timestamp, change_by = $Param{UserID} " .
    " WHERE id = $Param{TicketID}";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
      # add history
      $Self->HistoryAdd(
          TicketID => $Param{TicketID},
          CreateUserID => $Param{UserID},
          HistoryType => 'OwnerUpdate',
          Name => "\%\%$Param{NewUser}\%\%$Param{NewUserID}",
      );
      # send agent notify
      if ($Param{UserID} ne $Param{NewUserID} && 
           $Param{NewUserID} ne $Self->{ConfigObject}->Get('PostmasterUserID')) {
        if (!$Param{Comment}) {
            $Param{Comment} = '';
        }
        # get user data
        my %Preferences = $Self->{UserObject}->GetUserData(UserID => $Param{NewUserID});
        # send agent notification
        $Self->SendAgentNotification(
            Type => 'OwnerUpdate',
            UserData => \%Preferences,
            CustomerMessageParams => \%Param,
            TicketID => $Param{TicketID},
            UserID => $Param{UserID},
        );
      }
      # send customer notification email
      my %Preferences = $Self->{UserObject}->GetUserData(UserID => $Param{NewUserID});
      $Self->SendCustomerNotification(
          Type => 'OwnerUpdate',
          CustomerMessageParams => \%Preferences,
          TicketID => $Param{TicketID},
          UserID => $Param{UserID},
      );
      return 1;
    }
    else {
      return;
    }
}
# --

=item OwnerList()

returns the owner in the past as array with hash ref of the owner data 
(name, email, ...)
    
  my @Owner = $TicketObject->OwnerList(
      TicketID => 123,
  );

=cut

sub OwnerList {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db query
    my @User = ();
    my $SQL = "SELECT sh.name, ht.name, sh.create_by ".
        " FROM ".
        " ticket_history sh, ticket_history_type ht ".
        " WHERE ".
        " sh.ticket_id = $Param{TicketID} ".
        " AND ".
        " ht.name IN ('OwnerUpdate', 'NewTicket')  ".
        " AND ".
        " ht.id = sh.history_type_id".
        " ORDER BY sh.id";
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        # store result
        if ($Row[1] eq 'NewTicket') {
            if ($Row[2] ne '1') {
                push (@User, $Row[2]);
            }
        }
        elsif ($Row[1] eq 'OwnerUpdate') {
            if ($Row[0] =~ /^New Owner is '.+?' \(ID=(.+?)\)/) {
                push (@User, $1);
            }
        }
    }
    my @UserInfo = ();
    foreach (@User) {
        my %User = $Self->{UserObject}->GetUserData(UserID => $_, Cache => 1);
        push (@UserInfo, \%User);
    }
    return @UserInfo;
}
# --
sub PriorityLookup {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{Type} && !$Param{ID}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need Type or ID!");
      return;
    }
    # check if we ask the same request?
    if ($Param{Type}) {
        if (exists $Self->{"Ticket::Priority::PriorityLookup::$Param{Type}"}) {
            return $Self->{"Ticket::Priority::PriorityLookup::$Param{Type}"};
        }
    }
    else {
        if (exists $Self->{"Ticket::Priority::PriorityIDLookup::$Param{ID}"}) {
            return $Self->{"Ticket::Priority::PriorityIDLookup::$Param{ID}"};
        }
    }
    # db query
    my $SQL = '';
    if ($Param{Type}) {
        $SQL = "SELECT id FROM ticket_priority WHERE name = '".$Self->{DBObject}->Quote($Param{Type})."'";
    }
    else {
        $SQL = "SELECT name FROM ticket_priority WHERE id = ".$Self->{DBObject}->Quote($Param{ID})."";
    }
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        # store result
        if ($Param{Type}) {
            $Self->{"Ticket::Priority::PriorityLookup::$Param{Type}"} = $Row[0];
        }
        else {
            $Self->{"Ticket::Priority::PriorityIDLookup::$Param{ID}"} = $Row[0];
        }
    }
    # check if data exists
    if ($Param{Type}) {
        if (!exists $Self->{"Ticket::Priority::PriorityLookup::$Param{Type}"}) {
            $Self->{LogObject}->Log(
                Priority => 'error', 
                Message => "No TypeID for $Param{Type} found!",
            );
            return;
        }
        else {
            return $Self->{"Ticket::Priority::PriorityLookup::$Param{Type}"};
        }
    }
    else {
        if (!exists $Self->{"Ticket::Priority::PriorityIDLookup::$Param{ID}"}) {
            $Self->{LogObject}->Log(
                Priority => 'error', 
                Message => "No ID for $Param{ID} found!",
            );
            return;
        }
        else {
            return $Self->{"Ticket::Priority::PriorityIDLookup::$Param{ID}"};
        }
    }
}
# --

=item PrioritySet()

to set the ticket priority
    
  $TicketObject->PrioritySet(
      TicketID => 123,
      Priority => 'low',
      UserID => 213,
  );

  $TicketObject->PrioritySet(
      TicketID => 123,
      PriorityID => 2,
      UserID => 213,
  );

=cut

sub PrioritySet {
    my $Self = shift;
    my %Param = @_;
    # lookup!
    if (!$Param{PriorityID} && $Param{Priority}) {
        $Param{PriorityID} = $Self->PriorityLookup(Type => $Param{Priority});
    }
    if ($Param{PriorityID} && !$Param{Priority}) {
        $Param{Priority} = $Self->PriorityLookup(ID => $Param{PriorityID});
    }
    # check needed stuff
    foreach (qw(TicketID UserID PriorityID Priority)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    my %TicketData = $Self->TicketGet(%Param);
    # check if update is needed
    if ($TicketData{Priority} eq $Param{Priority}) {
       # update not needed
       return 1;
    }
    # permission check
    my %PriorityList = $Self->PriorityList(%Param);
    if (!$PriorityList{$Param{PriorityID}}) {
        $Self->{LogObject}->Log(
            Priority => 'notice', 
            Message => "Permission denied on TicketID: $Param{TicketID}!",
        );
        return;
    }
    # clear ticket cache
    $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db update
    my $SQL = "UPDATE ticket SET ticket_priority_id = $Param{PriorityID}, " .
        " change_time = current_timestamp, change_by = $Param{UserID} " .
        " WHERE id = $Param{TicketID} ";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
      # add history
      $Self->HistoryAdd(
          TicketID => $Param{TicketID},
          CreateUserID => $Param{UserID},
          HistoryType => 'PriorityUpdate',
          Name => "\%\%$TicketData{Priority}\%\%$TicketData{PriorityID}".
              "\%\%$Param{Priority}\%\%$Param{PriorityID}",
      );
      return 1;
    }
    else {
        return;
    }
}
# --

=item PriorityList()

to get the priority list for a ticket (depends on workflow, if configured)

  my %Priorities = $TicketObject->PriorityList(
      TicketID => 123,
      UserID => 123,
  );

  my %Priorities = $TicketObject->PriorityList(
      QueueID => 123,
      UserID => 123,
  );

=cut

sub PriorityList {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{UserID} && !$Param{CustomerUserID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need UserID or CustomerUserID!");
        return;
    }
    # check needed stuff
    if (!$Param{QueueID} && !$Param{TicketID}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need QueueID or TicketID!");
        return;
    }
    # sql 
    my $SQL = "SELECT id, name ".
        " FROM ".
        " ticket_priority ";
    my %Data = ();
    if ($Self->{DBObject}->Prepare(SQL => $SQL)) {
        while (my @Row = $Self->{DBObject}->FetchrowArray()) {
            $Data{$Row[0]} = $Row[1];
        }
#delete $Data{2};
        # workflow
        if ($Self->TicketWorkflow(
            %Param,
            Type => 'Priority',
            Data => \%Data,
         )) {
            return $Self->TicketWorkflowData();
        }
        # /workflow
        return %Data;
    }
    else {
        return;
    }
}
# --
sub HistoryTypeLookup {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{Type}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need Type!");
      return;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # check if we ask the same request?
    if (exists $Self->{"Ticket::History::HistoryTypeLookup::$Param{Type}"}) {
        return $Self->{"Ticket::History::HistoryTypeLookup::$Param{Type}"};
    }
    # db query
    my $SQL = "SELECT id FROM ticket_history_type WHERE name = '$Param{Type}'";
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        # store result
        $Self->{"Ticket::History::HistoryTypeLookup::$Param{Type}"} = $Row[0];
    }
    # check if data exists
    if (!exists $Self->{"Ticket::History::HistoryTypeLookup::$Param{Type}"}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "No TypeID for $Param{Type} found!");
        return;
    }
    else {
        return $Self->{"Ticket::History::HistoryTypeLookup::$Param{Type}"};
    }
}
# --

=item HistoryAdd()

add a history entry to an ticket

  $TicketObject->HistoryAdd(
      Name => 'Some Comment', 
      HistoryType => 'Move', # see system tables
      TicketID => 123,
      ArticleID => 1234, # not required!
      UserID => 123,
      CreateUserID => 123,
  );

=cut

sub HistoryAdd {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    if (!$Param{Name}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need Name!");
      return;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # lookup!
    if ((!$Param{HistoryTypeID}) && ($Param{HistoryType})) {
        $Param{HistoryTypeID} = $Self->HistoryTypeLookup(Type => $Param{HistoryType});
    }
    # check needed stuff
    foreach (qw(TicketID CreateUserID HistoryTypeID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    if (!$Param{ArticleID}) {
        $Param{ArticleID} = 0;
    }
    # get ValidID!
    if (!$Param{ValidID}) {
        $Param{ValidID} = $Self->{DBObject}->GetValidIDs();
    }
    # db insert
    my $SQL = "INSERT INTO ticket_history " .
    " (name, history_type_id, ticket_id, article_id, valid_id, " .
    " create_time, create_by, change_time, change_by) " .
        "VALUES " .
    "('$Param{Name}', $Param{HistoryTypeID}, $Param{TicketID}, ".
    " $Param{ArticleID}, $Param{ValidID}, " .
    " current_timestamp, $Param{CreateUserID}, current_timestamp, $Param{CreateUserID})";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
        return 1;
    }
    else {
        return;
    }
}
# --

=item HistoryGet()

get ticket history as array with hashes 
(TicketID, ArticleID, Name, CreateBy, CreateTime and HistoryType)

  my @HistoryLines = $TicketObject->HistoryGet(
      TicketID => 123,
      UserID => 123,
  );

=cut

sub HistoryGet {
    my $Self = shift;
    my %Param = @_;
    my @Lines;
    # check needed stuff
    foreach (qw(TicketID UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    my $SQL = "SELECT sh.name, sh.article_id, sh.create_time, sh.create_by, ".
        " ht.name ".
        " FROM ".
        " ticket_history sh, ticket_history_type ht ".
        " WHERE ".
        " sh.ticket_id = $Param{TicketID} ".
        " AND ".
        " ht.id = sh.history_type_id".
        " ORDER BY sh.id";
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray() ) {
          my %Data;
          $Data{TicketID} = $Param{TicketID};
          $Data{ArticleID} = $Row[1];
          $Data{Name} = $Row[0];
          $Data{CreateBy} = $Row[3];
          $Data{CreateTime} = $Row[2];
          $Data{HistoryType} = $Row[4];
          push (@Lines, \%Data);
    }
    # get user data
    foreach my $Data (@Lines) {
        my %UserInfo = $Self->{UserObject}->GetUserData(
            UserID => $Data->{CreateBy},
            Cached => 1
        );
        %{$Data} = (%{$Data}, %UserInfo);
    }
    return @Lines;
}
# --

=item HistoryDelete()

delete a ticket history (from storage)

  $TicketObject->HistoryDelete(
      TicketID => 123,
      UserID => 123,
  );

=cut

sub HistoryDelete {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # delete from db
    if ($Self->{DBObject}->Do(SQL => "DELETE FROM ticket_history WHERE ticket_id = $Param{TicketID}")) {
        return 1;
    }
    else {
        return;
    }
}
#--
sub TicketAccountedTimeGet {
    my $Self = shift;
    my %Param = @_;
    my $AccountedTime = 0;
    # check needed stuff
    if (!$Param{TicketID}) {
      $Self->{LogObject}->Log(Priority => 'error', Message => "Need TicketID!");
      return;
    }
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db query
    my $SQL = "SELECT time_unit " .
        " FROM " .
        " time_accounting " .
        " WHERE " .
        " ticket_id = $Param{TicketID} " .
        "  ";
    $Self->{DBObject}->Prepare(SQL => $SQL);
    while (my @Row = $Self->{DBObject}->FetchrowArray()) {
        $AccountedTime = $AccountedTime + $Row[0];
    }
    return $AccountedTime;
}
# --
sub TicketAccountTime {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(TicketID ArticleID TimeUnit UserID)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # check some wrong formats
    my $TimeUnit = $Param{TimeUnit};
    $TimeUnit =~ s/,/\./g;
    $TimeUnit = int($TimeUnit);
    # clear ticket cache
    $Self->{'Cache::GetTicket'.$Param{TicketID}} = 0;
    # db quote
    foreach (keys %Param) {
        $Param{$_} = $Self->{DBObject}->Quote($Param{$_});
    }
    # db update
    my $SQL = "INSERT INTO time_accounting ".
      " (ticket_id, article_id, time_unit, create_time, create_by, change_time, change_by) ".
      " VALUES ".
      " ($Param{TicketID}, $Param{ArticleID}, $TimeUnit, ".
      " current_timestamp, $Param{UserID}, current_timestamp, $Param{UserID}) ";
    if ($Self->{DBObject}->Do(SQL => $SQL)) {
      # add history
      my $AccountedTime = $Self->TicketAccountedTimeGet(TicketID => $Param{TicketID});
      my $HistoryComment = "\%\%$Param{TimeUnit}"; 
      if ($TimeUnit ne $Param{TimeUnit}) {
          $HistoryComment = "$TimeUnit time unit(s) accounted ($Param{TimeUnit} is invalid).";
      }
      else {
          $HistoryComment .= "\%\%$AccountedTime";
      }
      $Self->HistoryAdd(
          TicketID => $Param{TicketID},
          ArticleID => $Param{ArticleID},
          CreateUserID => $Param{UserID},
          HistoryType => 'TimeAccounting',
          Name => $HistoryComment, 
      );
      return 1;
    }
    else {
      return;
    }
}
# --
sub TicketWorkflow {
    my $Self = shift;
    my %Param = @_;
    # check needed stuff
    foreach (qw(UserID Type Data)) {
      if (!$Param{$_}) {
        $Self->{LogObject}->Log(Priority => 'error', Message => "Need $_!");
        return;
      }
    }
    # check if workflows are configured, if not, just return
    if (!$Self->{ConfigObject}->Get('TicketWorkflow') || $Param{UserID} == 1) {
        return;
    }
    my %Data = %{$Param{Data}};
    my %Checks = ();
    # use ticket data if ticket id is given
    if ($Param{TicketID}) {
        my %Ticket = $Self->TicketGet(%Param);
        $Checks{Ticket} = \%Ticket;
    }
    # use user data
    if ($Param{UserID}) {
        my %User = $Self->{UserObject}->GetUserData(UserID => $Param{UserID}, Cached => 1);
        foreach my $Type (@{$Self->{ConfigObject}->Get('System::Permission')}) {
            my @Groups = $Self->{GroupObject}->GroupMemberList(
                UserID => $Param{UserID},
                Result => 'Name',
                Type => $Type,
                Cached => 1,
            );
            $User{"Group_$Type"} = \@Groups;
        }
        $Checks{User} = \%User;
    }
    # use queue data (if given)
    if ($Param{QueueID}) {
        my %Queue = $Self->{QueueObject}->QueueGet(ID => $Param{QueueID}, Cache => 1);
        $Checks{Queue} = \%Queue;
    }
    # check workflow config
    my %Workflow = %{$Self->{ConfigObject}->Get('TicketWorkflow')};
    my %NewData = ();
    my $UseNewParams = 0;
    foreach my $StepT (sort keys %Workflow) {
        my %Step = %{$Workflow{$StepT}};
        # check force match
        my $ForceMatch = 1;
        foreach (keys %{$Step{Properties}}) {
            $ForceMatch = 0;
        }
        # set match params
        my $Match = 1;
        my $Match3 = 0;
        foreach my $Key (keys %Checks) {
#print STDERR "($StepT)Key: $Key\n";
          foreach my $Data (keys %{$Step{Properties}->{$Key}}) {
            my $Match2 = 0;
            foreach (@{$Step{Properties}->{$Key}->{$Data}}) {
                if (ref($Checks{$Key}->{$Data}) eq 'ARRAY') {
                    foreach my $Array (@{$Checks{$Key}->{$Data}}) {
                        if ($_ eq $Array) {
                            $Match2 = 1;
                            # debug log
                            if ($Self->{Debug} > 4) {
                                $Self->{LogObject}->Log(
                                    Priority => 'debug',
                                    Message => "Workflow '$StepT/$Key/$Data' MatchedARRAY ($_ eq $Array)",
                                );
                            }
                        }
                    }
                }
                else {
                    if ($_ eq $Checks{$Key}->{$Data}) {
                        $Match2 = 1;
                        # debug
                        if ($Self->{Debug} > 4) {
                            $Self->{LogObject}->Log(
                                    Priority => 'debug',
                                    Message => "Workflow '$StepT/$Key/$Data' Matched ($_ eq $Checks{$Key}->{$Data})",
                            );
                        }
                    }
                }
            }
            if (!$Match2) {
                $Match = 0;
            }
            $Match3 = 1;
          }
        }
        # check force option
        if ($ForceMatch) {
            $Match = 1;
            $Match3 = 1;
        }
        # debug log
        if ($Match && $Match3) {
            %NewData = ();
            if ($Self->{Debug} > 2) {
                $Self->{LogObject}->Log(
                    Priority => 'debug',
                    Message => "Matched Workflow '$StepT'->'$Param{Type}'",
                );
            }
        }
        # build new data hash 
        if (%Checks && $Match && $Match3 && $Step{Possible}->{Ticket}->{$Param{Type}}) {
            $UseNewParams = 1;
            # debug log
            if ($Self->{Debug} > 3) {
                $Self->{LogObject}->Log(
                    Priority => 'debug',
                    Message => "Workflow '$StepT' used with Possible:'$Param{Type}'",
                );
            }
            # possible list
            foreach my $ID (keys %Data) {
                foreach my $New (@{$Step{Possible}->{Ticket}->{$Param{Type}}}) {
                    if ($Data{$ID} eq $New) {
                        $NewData{$ID} = $Data{$ID};
                        if ($Self->{Debug} > 4) {
                            $Self->{LogObject}->Log(
                                Priority => 'debug',
                                Message => "Workflow '$StepT' param '$Data{$ID}' used with Possible:'$Param{Type}'",
                            );
                        }
                    }
                }
            }
        }
        if (%Checks && $Match && $Match3 && $Step{PossibleNot}->{Ticket}->{$Param{Type}}) {
            $UseNewParams = 1;
            # debug log
            if ($Self->{Debug} > 3) {
                $Self->{LogObject}->Log(
                    Priority => 'debug',
                    Message => "Workflow '$StepT' used with PossibleNot:'$Param{Type}'",
                );
            }
            # not possible list
            foreach my $ID (keys %Data) {
                my $Match = 1;
                foreach my $New (@{$Step{PossibleNot}->{Ticket}->{$Param{Type}}}) {
                    if ($Data{$ID} eq $New) {
                        $Match = 0;
                    }
                }
                if ($Match) {
                    $NewData{$ID} = $Data{$ID};
                    if ($Self->{Debug} > 4) {
                        $Self->{LogObject}->Log(
                            Priority => 'debug',
                            Message => "Workflow '$StepT' param '$Data{$ID}' in not used with PossibleNot:'$Param{Type}'",
                        );
                    }
                }
            }
        }
        # return new params
        if ($UseNewParams && $Step{StopAfterMatch}) {
            $Self->{TicketWorkflowData} = \%NewData;
            return 1;
        }
    }
    if ($UseNewParams) {
        $Self->{TicketWorkflowData} = \%NewData;
        return 1;
    }
    return;
}
# --
sub TicketWorkflowData {
    my $Self = shift;
    my %Param = @_;
    return %{$Self->{TicketWorkflowData}};
}
# --
1; 

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (http://otrs.org/).  

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (GPL). If you
did not receive this file, see http://www.gnu.org/licenses/gpl.txt.

=head1 VERSION

$Revision: 1.91 $ $Date: 2004-04-18 13:59:02 $

=cut
