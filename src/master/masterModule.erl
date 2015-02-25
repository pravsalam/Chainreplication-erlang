-module(masterModule).
-export([start/0,master/8]).

master(0,0,0,0,0,0,0,0) -> 
	HeadsTable = ets:new(bank_heads,[]),	
	TailsTable = ets:new(bank_tails, []),
	ServersTable = ets:new(bank_servers, [bag]),
	ClientsTable = ets:new(bank_clients, [bag]),
	RoleTable = ets:new(server_roles, []),
	PredTable = ets:new(server_pred, []),
	SuccTable = ets:new(server_suc, []),
	LastHeard = ets:new(server_last_heard, []),
	master(HeadsTable,TailsTable,ServersTable,ClientsTable,RoleTable,PredTable,SuccTable,LastHeard);

master(HeadsTable,TailsTable,ServersTable,ClientsTable,RoleTable,PredTable,SuccTable,LastHeard) ->
	receive 
		%%register client
		{'register',Client_PID,BankName} ->	
			error_logger:info_msg("Master: Registering Client ~p~n",[Client_PID]),
			ets:insert(ClientsTable,{BankName,Client_PID}),
			Head = ets:lookup_element(HeadsTable,BankName,2),
			Client_PID ! {'head_update',BankName,Head},
			Tail = ets:lookup_element(TailsTable,BankName,2),
			Client_PID ! {'tail_update',BankName,Tail};
		{'head_info',Client_PID, BankName} ->
			Head = ets:lookup_element(HeadsTable,BankName,2),
			Client_PID ! {'head_update',BankName,Head};
		{'tail_info',Client_PID, BankName} ->
			Tail = ets:lookup_element(TailsTable,BankName,2),
			Client_PID ! {'tail_update',BankName,Tail};
		{'join_as_tail',Server_PID,BankName} ->
			BankHasServers = ets:member(ServersTable,BankName),
			if 
				BankHasServers ->
					Tail = ets:lookup_element(TailsTable,BankName,2),
					ets:insert(ServersTable,{BankName,Server_PID}),
					ets:insert(PredTable,{Server_PID,Tail}),
					ets:insert(SuccTable,{Server_PID,none}),
					ets:insert(SuccTable,{Tail,Server_PID}),
					ets:insert(RoleTable,{Server_PID,waiting_tobe_tail}),
					ets:insert(LastHeard,{Server_PID,calendar:datetime_to_gregorian_seconds(calendar:universal_time())}),
					PrintList = [BankName,Server_PID],
					error_logger:info_msg("Master: New tail joining Bank ~w~n ",[PrintList]),
					Server_PID ! {'ack_join_as_tail',Tail},
					Tail ! {'new_tail_joined',Server_PID};
				true ->					
					ets:insert(HeadsTable,{BankName,Server_PID}),
					ets:insert(TailsTable,{BankName,Server_PID}),
					ets:insert(ServersTable,{BankName,Server_PID}),
					ets:insert(PredTable,{Server_PID,none}),
					ets:insert(SuccTable,{Server_PID,none}),
					ets:insert(RoleTable,{Server_PID,stand_alone}),
					PrintList = [BankName,Server_PID],
					error_logger:info_msg("Master: First Server joined Bank: ~w~n",[PrintList]),
					ets:insert(LastHeard,{Server_PID,calendar:datetime_to_gregorian_seconds(calendar:universal_time())}),
					Server_PID ! {'stand_alone'}	
			end;
		{'ack_as_tail',BankName,Server_PID} ->
			PrintList = [BankName,Server_PID],
			error_logger:info_msg("Master: New tail joined Bank: ~w~n",[PrintList]),
			CurrTail = ets:lookup_element(TailsTable,BankName,2),
			CurrTailRole = ets:lookup_element(RoleTable,CurrTail,2),
			if 
				CurrTailRole =:= stand_alone -> 
					ets:insert(RoleTable,{CurrTail,head}),				
					CurrTail ! {'promote_to_head'};
				true ->
					ets:insert(RoleTable,{CurrTail,internal}),
					CurrTail ! {'become_internal'}
			end,
			ets:insert(TailsTable,{BankName,Server_PID}),
			ets:insert(RoleTable,{Server_PID,tail});
		{'predecessor_reconcile',LastReq,Server_PID} ->
			Pred = ets:lookup_element(PredTable,Server_PID,2),
			ets:insert(SuccTable,{Pred,Server_PID}),
			Pred ! {'successor_update',Server_PID,LastReq};
		%%receive heartbeats
		{'heartbeat',BankName,Server_PID} ->
			ets:insert(LastHeard,{Server_PID,calendar:datetime_to_gregorian_seconds(calendar:universal_time())}),
			First = ets:first(ServersTable),
			self() ! {'check_if_servers_are_alive',First};
		%%check if servers are alive
		{'check_if_servers_are_alive','$end_of_table'} -> ok;
		{'check_if_servers_are_alive',First} ->
			List = ets:lookup_element(ServersTable,First,2),
			Length = length(List),
			self() ! {'check_if_servers_for_bank_are_alive',First,List,Length},
			Next = ets:next(ServersTable,First),
                        self() ! {'check_if_servers_are_alive',Next};
		{'check_if_servers_for_bank_are_alive',First,List,0} -> ok;
		{'check_if_servers_for_bank_are_alive',First,List,Length} ->
			Server = lists:nth(Length,List),	
			self() ! {'check_if_server_is_alive',First,Server},
			self() ! {'check_if_servers_for_bank_are_alive',First,List,Length-1};
		{'send_to_clients','head_update',BankName,Clients,0} ->
			ok;		
		{'send_to_clients','head_update',BankName,Clients,Len} ->
			Cli = lists:nth(Len,Clients),
			Head = ets:lookup_element(HeadsTable,BankName,2),
			Cli ! {'head_update',BankName,Head},
			self() ! {'send_to_clients','head_update',BankName,Clients,Len-1};
		{'send_to_clients','tail_update',BankName,Clients,0} ->
			ok;
		{'send_to_clients','tail_update',BankName,Clients,Len} ->
			Cli = lists:nth(Len,Clients),
			Tail = ets:lookup_element(TailsTable,BankName,2),
			Cli ! {'tail_update',BankName,Tail},
			self() ! {'send_to_clients','tail_update',BankName,Clients,Len-1};
		{'check_if_server_is_alive',BankName,Server_PID} ->
			LastHeardTime = ets:lookup_element(LastHeard,Server_PID,2),
			Diff = calendar:datetime_to_gregorian_seconds(calendar:universal_time()) - LastHeardTime,
			if	
				Diff >= 10 ->
					Role = ets:lookup_element(RoleTable,Server_PID,2),
					if 
						Role =:= head->
							error_logger:info_msg("Master: ~p head died~n",[BankName]),
							Succ = ets:lookup_element(SuccTable,Server_PID,2),
							ets:insert(HeadsTable,{BankName,Succ}),
							SuccRole = ets:lookup_element(RoleTable,Succ,2),
							if
								SuccRole =:= tail -> 
									ets:insert(RoleTable,{Succ,stand_alone});
								true ->
									error_logger:info_msg("New head ~w~n",[Succ]),
									ets:insert(RoleTable,{Succ,head})
							end,
							Succ ! {'promote_to_head'},
							Clients = ets:lookup_element(ClientsTable,BankName,2),
							Len = length(Clients),	
							self() ! {'send_to_clients','head_update',BankName,Clients,Len};
						Role =:= tail ->
							Succ = ets:lookup_element(SuccTable,Server_PID,2),
							if 
								Succ =:= none ->
									error_logger:info_msg("Master: ~p tail died ~n",[BankName]),
									Pred = ets:lookup_element(PredTable,Server_PID,2),
									ets:insert(TailsTable,{BankName,Pred}),
									PredRole = ets:lookup_element(RoleTable,Pred,2),
									if 
										PredRole =:= head ->
											ets:insert(RoleTable,{Succ,stand_alone});
										true -> 
											error_logger:info_msg("New Tail ~w~n",[Pred]),
											ets:insert(RoleTable,{Succ,tail})
									end,
									Pred ! {'promote_to_tail'},
									Clients = ets:lookup_element(ClientsTable,BankName,2),
									Len = length(Clients),	
									self() ! {'send_to_clients','tail_update',BankName,Clients,Len};
								true ->
									error_logger:info_msg("Old tail died while extending chain~n"),
									PrintList = [BankName,Succ],
									error_logger:info_msg("New Tail: ~p ~n",[PrintList]),
									ets:insert(TailsTable,{BankName,Succ}),
									Pred = ets:lookup_element(PredTable,Server_PID,2),
									ets:insert(PredTable,{Succ,Pred}),
									ets:insert(RoleTable,{Succ,tail}),
									Succ ! {'promote_to_tail'},
									Succ ! {'predecessor_update',Pred}
							end;
						Role =:= internal ->
							error_logger:info_msg("~p Internal server died~n",[BankName]),
							Succ = ets:lookup_element(SuccTable,Server_PID,2),
							Pred = ets:lookup_element(PredTable,Server_PID,2),
							ets:insert(PredTable,{Succ,Pred}),
							Succ ! {'predecessor_update',Pred};
						Role =:= waiting_tobe_tail ->
							error_logger:info_msg("New tail died while extending chain,aborting chain extension!~n"),
							Pred = ets:lookup_element(PredTable,Server_PID,2),
							ets:insert(SuccTable,{Pred,none});
						Role =:= stand_alone ->
							Succ = ets:lookup_element(SuccTable,Server_PID,2),
							if
								Succ =/= none ->
									ets:insert(RoleTable,{Succ,stand_alone}),
									ets:insert(HeadsTable,{BankName,Succ}),
									ets:insert(TailsTable,{BankName,Succ});
								true ->
									ok				
							end;
						true ->
							ok
					end,
					ets:delete_object(ServersTable,{BankName,Server_PID}),
					ets:delete(RoleTable,Server_PID),
					ets:delete(SuccTable,Server_PID),
					ets:delete(PredTable,Server_PID),					
					ets:delete(LastHeard,Server_PID);
				true ->
					ok
			end
	end,
	master(HeadsTable,TailsTable,ServersTable,ClientsTable,RoleTable,PredTable,SuccTable,LastHeard).

start() ->	
	Master_PID = spawn(masterModule, master, [0,0,0,0,0,0,0,0]).	
 
