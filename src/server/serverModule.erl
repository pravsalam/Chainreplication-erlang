-module(serverModule).
-export([server/10,start/4]).

server(BankName, Master,0,0,0,0,0,0,Delay,Lifetime) ->
	timer:sleep(Delay*1000),
	SuccTable = ets:new(succ_info,[]),
	PredTable = ets:new(pred_info,[]),
	RoleTable = ets:new(role_info,[]),
	ProcessedTable = ets:new(processed_trans,[]),
	SentTable = ets:new(sent_trans,[]),
	AccountTable = ets:new(account_info,[]),
	Master ! {'join_as_tail',self(),BankName},
	{ok,Timer} = timer:send_interval(5000,Master,{'heartbeat',BankName,self()}),
	timer:send_after(Lifetime*1000,{'kill_me',Timer}),
	server(BankName, Master,SuccTable,PredTable,RoleTable,ProcessedTable,SentTable,AccountTable,Delay,Lifetime);

server(BankName, Master,SuccTable,PredTable,RoleTable,ProcessedTable,SentTable,AccountTable,Delay,Lifetime) ->
	receive
		%%Killing After Liftime
		{'kill_me',Timer} ->
			error_logger:info_msg("Server:Killing Server ~w~n",[self()]),
			timer:cancel(Timer),
			exit(self(),ok);
		%%New Tail has received Ack from master
		{'ack_join_as_tail',Pred} ->
			%% role will change to waiting_tobe_tail 
			RoleExist = ets:member(RoleTable, role),
			if
				RoleExist ->
					ets:delete(RoleTable, role);
				true ->
					ok
			end,
			ets:insert(RoleTable, {role,waiting_tobe_tail}),

			PredExist = ets:member(PredTable, predecessor),
			if
				PredExist ->
					ets:delete(PredTable, predecessor);
				true ->
					ok
			end,
			ets:insert(PredTable, {predecessor,Pred});
		%%Standalone from master
		{'stand_alone'} ->
			%% Stand alone server
			RoleExist  = ets:member(RoleTable, role),
			if
				RoleExist ->
					ets:delete(RoleTable, role);
				true ->
					ok
			end,
			ets:insert(RoleTable,{role,stand_alone});
		%%Old tail gets notified about new tail
		{'new_tail_joined',Tail} ->
			%% change successor
			SuccExit = ets:member(SuccTable, successor),
			if 
				SuccExit ->
					ets:delete(SuccTable, successor);
				true ->
					ok
			end,
			ets:insert(SuccTable, {successor, Tail}),

			%% change Role
			Role = ets:lookup_element(RoleTable, role,2),
			if 
				Role =:= stand_alone ->
					ets:delete(RoleTable, role),
					ets:insert(RoleTable, {role,head});
				%%Role =:= tail ->
				%%	ets:delete(RoleTable, role),
				%%	ets:insert(RoleTable, {role,transient_tail});
				true ->
					ok
			end,
			FirstReqId = ets:first(ProcessedTable),
			if 
				FirstReqId =/= '$end_of_table' ->
					self() ! {'transfer_proctable',FirstReqId, Tail};
				true ->
					Tail ! {'end_of_sent'}	
			end;
			%Tail ! {'end_of_sent'};
		%%Transfering Requests to New tail
		{'transfer_proctable',SyncReqId, Tail} ->
			error_logger:info_msg("Sending new tail: ~p~n",[SyncReqId]),
			[{ReqId, Client, AccountNumber, Amount, Balance}|_] = ets:lookup(ProcessedTable, SyncReqId),
			Tail ! {'sync_proctable', ReqId, Client, AccountNumber, Amount, Balance},
			NextReqId = ets:next(ProcessedTable, SyncReqId),
			if 
				NextReqId =/= '$end_of_table' ->
					self() ! {'transfer_proctable', NextReqId, Tail};
				true ->
					Tail ! {'end_of_sent'}
			end;
		%%Syncing processedTrans with Predecessor
		{'sync_proctable', ReqId, Client, AccountNumber, Amount, Balance} -> 
			ets:insert(ProcessedTable, {ReqId, Client, AccountNumber, Amount, Balance});
			
		{'promote_to_head'} ->
			%% promoted to head
			error_logger:info_msg("Server:I am new head ~w~n",[self()]),
			PredExists  = ets:member(PredTable, predecessor),
			if
				PredExists ->
					ets:delete(PredTable, predecessor);
				true ->
					ok
			end,
			Role = ets:lookup_element(RoleTable, role, 2),
			if
				Role =:= tail ->
					ets:delete(RoleTable, role),
					ets:insert(RoleTable, {role, stand_alone});
				true ->
					ets:delete(RoleTable, role),
					ets:insert(RoleTable, {role,head})
			end;
		%%Promoted to tail
		{'promote_to_tail'} ->
			error_logger:info_msg("Server:I am new tail ~w~n",[self()]),
			SuccExists = ets:member(SuccTable, successor),
			if
				SuccExists ->
					ets:delete(SuccTable, successor);
				true ->
					ok
			end, 
			Role = ets:lookup_element(RoleTable, role, 2),
			ets:delete(RoleTable, role),
			if
				Role =:= head ->
					ets:insert(RoleTable, {role, stand_alone});
				true ->
					ets:insert(RoleTable, {role, tail})
			end;
		%%New Predecessor
		{'predecessor_update',NewPred} ->
			PrintList = [self(),NewPred],
			error_logger:info_msg("Server:I have new predecessor ~p ~n",[PrintList]),
			PredExists = ets:member(PredTable, predecessor),
			if
				PredExists ->
					ets:delete(PredTable, predecessor);
				true ->
					ok
			end, 
			ets:insert(PredTable, {predecessor, NewPred}),
			LastRow = ets:last(SentTable),
			Master ! { 'predecessor_reconcile',LastRow,self()};
		%%New successor
		{'successor_update', NewSucc, LastProcReqId} ->
			PrintList = [self(),NewSucc],
			error_logger:info_msg("Server:I have new successor ~p~n",[PrintList]),
			SuccExists = ets:member(SuccTable, successor),

			if 
				SuccExists ->
					ets:delete(SuccTable, successor);
				true ->
					ok
			end,
			ets:insert(SuccTable, {successor, NewSucc}),
			if 
				LastProcReqId =:= '$end_of_table' ->
					NextReqId = ets:first(SentTable);
				true ->
					NextReqId  = ets:next(SentTable, LastProcReqId)
			end,
			if 
				NextReqId =/= '$end_of_table' ->
					ReqIdExists = ets:member(ProcessedTable, NextReqId),
					if 
						ReqIdExists ->
							[{ReqId, Client, AccountNumber, Amount, Balance}|_] = ets:lookup(ProcessedTable, NextReqId),
							error_logger:info_msg("Sending to new successor: ~p~n",[ReqId]),
							NewSucc ! {'account_update', ReqId,Client, processed, AccountNumber,Amount, Balance};
						true ->
							ok
					end,
					self() ! {'successor_update', NewSucc, NextReqId};
				true ->
					ok
					%%NewSucc ! {'end_of_sent'}
			end;
		%%Transfer of ReqId to new tail done
		{'end_of_sent'} ->			
			RoleExist = ets:member(RoleTable, role),
			if 
				RoleExist ->
					ets:delete(RoleTable, role);
				true ->
					ok
			end, 
			ets:insert(RoleTable,{role, tail}),
			Master ! {'ack_as_tail',BankName,self()};
		%%Become internal
		{'become_internal'} ->
			ets:insert(RoleTable, {role, internal});
		%%Ack Sync
		{'ack_sync',ReqID} ->
			Check1 = ets:member(SentTable, ReqID),
			Check2 = ets:member(PredTable,predecessor),
			if Check1 ->
					ets:delete(SentTable, ReqID)
			end,
			if Check2 ->
					[{predecessor,Pred}|_]=ets:lookup(PredTable,predecessor),
					Pred ! {'ack_sync'}
			end;
		%%Account Update
		{'account_update', ReqID, Client, Result, AccountNumber, Amount, Balance}->
			HasSuccessor = ets:member(SuccTable, successor),
			TransExists = ets:member(ProcessedTable, ReqID),
			if
				TransExists ->
					ok;
				true ->
					%% is account present
					IsAccountPresent = ets:member(AccountTable, AccountNumber),
					if
					       Result =:= processed->
						       	if 
							       IsAccountPresent ->
								       ets:delete(AccountTable, AccountNumber);
								true ->
									ok
							end,
							ets:insert(AccountTable, {AccountNumber, Balance}),
							ets:insert(ProcessedTable, {ReqID, Client,AccountNumber,Amount, Balance});
						true ->
							ok
					end
			end,
			if
				HasSuccessor->
					[{successor,Succ}|_] = ets:lookup(SuccTable,successor),
					ets:insert(SentTable,{ReqID}),
					Succ ! {'account_update',ReqID, Client,Result, AccountNumber, Amount, Balance};
				true ->
					Pred = ets:lookup_element(PredTable, predecessor, 2),
					Client ! {'reply',ReqID, Result, AccountNumber, Balance},
					if 
						Pred ->
							Pred ! {'ack_sync', ReqID};
						true ->
							ok
					end
			end;
		{'balance', Client, ReqID, AccountNumber, _} ->
			Role = ets:lookup_element(RoleTable, role,2),
			if
				Role =:= tail->
					AccountExists = ets:member(AccountTable,AccountNumber),
					if 	
						AccountExists->
							Balance = ets:lookup_element(AccountTable,AccountNumber, 2),
							Client ! {'reply',ReqID,processed,AccountNumber, Balance};
						true->
							Client ! {'reply',ReqID, illegal, AccountNumber, 0}
					end;
				true->
					%% this is not tail 
					Client ! {'reply',ReqID, illegal, AccountNumber, 0}
			end;
		{'deposit',Client, ReqID, AccountNumber, Amount} ->
			Role = ets:lookup_element(RoleTable, role, 2),
			ReqIDExist = ets:member(ProcessedTable, ReqID),
			if
				ReqIDExist->
					ProcessedAmount = ets:lookup_element(ProcessedTable,ReqID,4),
					FinalBalance = ets:lookup_element(ProcessedTable, ReqID, 5),
					if
						Amount =:= ProcessedAmount ->
							Outcome = processed;
						true->
							Outcome = inconsistent_with_history
					end,
					if 
						Role =:= stand_alone ->
							Client ! {'reply', ReqID, Outcome, AccountNumber, FinalBalance};
						true->
							Succ = ets:lookup_element(SuccTable, successor,2),
							ets:insert(SentTable, {ReqID}),
							Succ ! {'account_update',ReqID, Client, Outcome, AccountNumber, Amount, FinalBalance}
					end;

				true->
					if 
						Role =:= head; Role =:= stand_alone ->
							AccountExists  = ets:member(AccountTable, AccountNumber),
							if 
								AccountExists->
									CurBalance = ets:lookup_element(AccountTable, AccountNumber, 2),
									NewBalance = CurBalance + Amount,
									ets:delete(AccountTable, AccountNumber),
									ets:insert(AccountTable,{AccountNumber, NewBalance});
								true->
									ets:insert(AccountTable, {AccountNumber,Amount})
							end,
							CheckBalance = ets:lookup_element(AccountTable,AccountNumber, 2),
							ets:insert(ProcessedTable, {ReqID, Client,AccountNumber, Amount, CheckBalance}),
							if 
								Role =:= stand_alone ->
									Client ! {'reply', ReqID, processed, AccountNumber, CheckBalance};
								true->
									Succ = ets:lookup_element(SuccTable, successor,2),
									ets:insert(SentTable, {ReqID}),
									Succ ! {'account_update',ReqID, Client, processed, AccountNumber, Amount, CheckBalance}
							end;
						true->
							Client ! {'reply',ReqID, illegal, AccountNumber, 0}
					end
			end;

		{'withdraw',Client, ReqID, AccountNumber, Amount} ->
			Role = ets:lookup_element(RoleTable, role, 2),
			ReqIDExist = ets:member(ProcessedTable, ReqID),
			if
				ReqIDExist->
					ProcessedAmount = ets:lookup_element(ProcessedTable,ReqID,4),
					FinalBalance = ets:lookup_element(ProcessedTable, ReqID, 5),
					if
						Amount =:= ProcessedAmount ->
							Outcome = processed;
						true->
							Outcome = inconsistent_with_history
					end,
					if 
						Role =:= stand_alone ->
							Client ! {'reply', ReqID, Outcome, AccountNumber, FinalBalance};
						true->
							Succ = ets:lookup_element(SuccTable, successor,2),
							ets:insert(SentTable,{ReqID}),
							Succ ! {'account_update',ReqID, Client, Outcome, AccountNumber, Amount, FinalBalance}
					end;

				true->
					if 
						Role =:= head; Role =:= stand_alone ->
							AccountExists  = ets:member(AccountTable, AccountNumber),
							if 
								AccountExists ->
									CurBalance = ets:lookup_element(AccountTable, AccountNumber, 2),
									if 
										Amount < CurBalance ->
											NewBalance = CurBalance - Amount,
											ets:delete(AccountTable, AccountNumber),
						                                        ets:insert(AccountTable,{AccountNumber, NewBalance}),
											ets:insert(ProcessedTable, {ReqID, Client,AccountNumber, Amount, NewBalance}),
											if
												Role =:= stand_alone ->
													Client ! {'reply',ReqID, processed, AccountNumber, NewBalance};
												true->
													Succ = ets:lookup_element(SuccTable, successor,2),
													ets:insert(SentTable, {ReqID}),
								                   			Succ ! {'account_update',ReqID, Client, processed, AccountNumber, Amount, NewBalance}
											end;
										true->
											if
												Role =:= stand_alone ->
													Client ! {'reply',ReqID, insuf_fund, AccountNumber, CurBalance};
												true->
													Succ = ets:lookup_element(SuccTable, successor,2),
													ets:insert(SentTable,{ReqID}),
								                    			Succ ! {'account_update',ReqID, Client, insuf_fund, AccountNumber, Amount, CurBalance}
											end

									end;
								true->
									ets:insert(AccountTable, {AccountNumber,0}),
									ets:insert(ProcessedTable,{ ReqID, Client, AccountNumber, Amount, 0}),
									if
										Role =:= stand_alone ->
											Client ! {'reply',ReqID, insuf_fund, AccountNumber, 0};
										true->
												Succ = ets:lookup_element(SuccTable, successor,2),
												ets:insert(SentTable,{ReqID}),
								                Succ ! {'account_update',ReqID, Client, insuf_fund, AccountNumber, Amount, 0}
									end
							end;
						true->
							Client ! {'reply',ReqID, illegal, AccountNumber, 0}
					end
		end
	end,
	server(BankName,Master,SuccTable,PredTable,RoleTable,ProcessedTable,SentTable,AccountTable,Delay,Lifetime).

%getreqids(First, Table)->
%	if	First =:= '$end_of_table' ->
%			[];
%		First =/= '$end_of_table' ->
%			[First|getreqids(ets:next(Table, First),Table)]
%	end.

start(Master_PID,BankName,Servers,0) -> ok;
start(Master_PID,BankName,Servers,NoOfServers) ->
	Delay = element(2,element(3,lists:nth(NoOfServers,Servers))),
	LifeTime = element(2,element(2,lists:nth(NoOfServers,Servers))),
	spawn(serverModule,server,[BankName,Master_PID,0,0,0,0,0,0,Delay,LifeTime]),
	start(Master_PID,BankName,Servers,NoOfServers-1).
