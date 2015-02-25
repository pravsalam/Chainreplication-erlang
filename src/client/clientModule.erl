-module(clientModule).
-export([start/4,client/8,handleRequests/2,sendProbRequests/5,sendRequests/3]).

client(Master_PID,BankName,ClientRequestsInfo,0,0,0,0,DropRate)->
	ResponseTable = ets:new(response_table, []),
	CounterTable = ets:new(counter_table, []),		
	ets:insert(CounterTable,{count,1}),
	HeadsTable = ets:new(bank_heads, []),	
	TailsTable = ets:new(bank_tails, []),
	Master_PID ! {'register',self(),BankName},
	client(Master_PID,BankName,ClientRequestsInfo,ResponseTable,CounterTable,HeadsTable,TailsTable,DropRate);

client(Master_PID,BankName,ClientRequestsInfo,ResponseTable,CounterTable,HeadsTable,TailsTable,DropRate) ->
	receive
		%%receive response to transaction
		{'reply',ReqID,Outcome,AccountNumber,Balance} ->
			ets:insert(ResponseTable,{ReqID,Outcome,AccountNumber,Balance}),
			PrintList = [ReqID,Outcome,AccountNumber,Balance],
			Check = ets:member(ResponseTable,ReqID),
			error_logger:info_msg("Client: Received Response from Server ~w~n",[PrintList]),
			ets:insert(ResponseTable,{ReqID,Outcome, AccountNumber, Balance});
		%%handle head update
		{'head_update',BankName,Head} ->
			error_logger:info_msg("Client: Head Update Received~n"),
			Check = ets:member(HeadsTable,BankName),
			if 
				Check ->
					ets:delete(HeadsTable,BankName),
					ets:insert(HeadsTable,{BankName,Head});
				true ->
					ets:insert(HeadsTable,{BankName,Head})
			end;
		%%handle tail update
		{'tail_update',BankName,Tail} ->
			error_logger:info_msg("Client: Tail Update Received~n"),
			Check = ets:member(TailsTable,BankName),
			if 
				Check ->
					ets:delete(TailsTable,BankName),
					ets:insert(TailsTable,{BankName,Tail});
				true ->
					ets:insert(TailsTable,{BankName,Tail}),
					handleRequests(ClientRequestsInfo,self())
			end;
		%%send balance request
		{'balance',AccountNumber, 0} ->
			Seq = ets:lookup_element(CounterTable,count,2),
			Index = ets:lookup_element(CounterTable,count,2),
			ets:update_element(CounterTable,count,{2,Index+1}),	
			ReqId = [BankName] ++ [self()] ++ [Seq],
			Tail =  ets:lookup_element(TailsTable,BankName,2),
			error_logger:info_msg("Client: Sending Get Balance Request ~p~n",[ReqId]),
			random:seed(now()),
        		R = random:uniform(),
			if R >= DropRate ->
				Tail ! {'balance',self(),ReqId, AccountNumber, 0};
			 true -> error_logger:info_msg("Client:Dropping Request ~p~n",[ReqId])
			end,
			timeResponse(self(),ReqId,Tail,'balance',AccountNumber,0,3000,3);
		%%send deposit request
		{'deposit',AccountNumber,Amount} ->
			Seq = ets:lookup_element(CounterTable,count,2),
			Index = ets:lookup_element(CounterTable,count,2),
			ets:update_element(CounterTable,count,{2,Index+1}),	
			ReqId = [BankName] ++ [self()] ++ [Seq],
			Head =  ets:lookup_element(HeadsTable,BankName,2),
			error_logger:info_msg("Client: Sending Deposit Request ~p~n",[ReqId]),
			random:seed(now()),
        		R = random:uniform(),
			if R>= DropRate ->
				Head ! {'deposit',self(), ReqId, AccountNumber, Amount};
			true -> error_logger:info_msg("Client:Dropping Request ~p~n",[ReqId]) 
			end,
			timeResponse(self(),ReqId,Head,'deposit',AccountNumber,Amount,3000,3);
		%%send withdraw request		
		{'withdraw',AccountNumber,Amount} ->
			Seq = ets:lookup_element(CounterTable,count,2),
			Index = ets:lookup_element(CounterTable,count,2),
			ets:update_element(CounterTable,count,{2,Index+1}),	
			ReqId = [BankName] ++ [self()] ++ [Seq],
			Head =  ets:lookup_element(HeadsTable,BankName,2),
			error_logger:info_msg("Client: Sending Withdraw Request ~p~n",[ReqId]),
			random:seed(now()),
        		R = random:uniform(),
			if R>= DropRate ->
				Head ! {'withdraw',self(),ReqId, AccountNumber, Amount};
			true -> error_logger:info_msg("Client:Dropping Request ~p~n",[ReqId])
			end,
			timeResponse(self(),ReqId,Head,'withdraw',AccountNumber,Amount,3000,3);
		%%check if response is received before timeout
		{'checkResponse',ReqId,PID,Type,AccountNumber,Amount,0} ->  error_logger:info_msg("Client: retry count 0~n");
		{'checkResponse',ReqId,PID,Type,AccountNumber,Amount,Try} ->
			Check = ets:member(ResponseTable,ReqId),
			if 
				Check ->
					ok;
				true ->
					error_logger:info_msg("Client: Did not receive response, resending~n"),
					PID ! {Type,self(),ReqId,AccountNumber,Amount},
					timeResponse(self(),ReqId,PID,Type,AccountNumber,Amount,3000,Try-1)
			end							
	end,
	client(Master_PID,BankName,ClientRequestsInfo,ResponseTable,CounterTable,HeadsTable,TailsTable,DropRate).

%%check for timeout
timeResponse(Cid,ReqId,PID,Type,AccountNumber,Amount,T,Try) ->
	if 
		T > 0 ->
			receive
			after T ->
				true
			end,
			Cid ! {'checkResponse',ReqId,PID,Type,AccountNumber,Amount,Try};
		true ->
			ok
	end.
%%handle 2 types of config file requests
handleRequests(ClientRequestsInfo,Cid) ->
	TotalReq = element(2,element(1,ClientRequestsInfo)),
	Requests = element(2,element(2,ClientRequestsInfo)),
	if 
		Requests =/= [] ->
			sendRequests(Cid,Requests,TotalReq);
		true ->
			GetBalP = element(2,element(3,ClientRequestsInfo)),	
			DepP = element(2,element(4,ClientRequestsInfo)),	
			WithP = element(2,element(5,ClientRequestsInfo)),
			sendProbRequests(Cid,GetBalP,DepP,WithP,TotalReq)
	end.
%%send requests 
sendRequests(Cid,Requests,0) -> ok;
sendRequests(Cid,Requests,LenOfReq) ->
	Type = element(1,lists:nth(LenOfReq,Requests)),
	AccNo = element(2,lists:nth(LenOfReq,Requests)),
	Amount = element(3,lists:nth(LenOfReq,Requests)),
	Cid ! {Type,AccNo,Amount},
	sendRequests(Cid,Requests,LenOfReq-1).

%%send requests according to probability
sendProbRequests(Cid,GetBalP,DepP,WithP,0) -> ok;
sendProbRequests(Cid,GetBalP,DepP,WithP,NoOfReq) ->
	random:seed(now()),
	R = random:uniform(),
	AccNo = random:uniform(1000) + 2000,
	Amount = random:uniform(200) + 100,
	if 
		R<GetBalP -> 
			Cid ! {'balance',AccNo,0};
		R>=GetBalP andalso R<(GetBalP+DepP) ->
			Cid ! {'deposit',AccNo,Amount};
		R>=(GetBalP+DepP) andalso R<(GetBalP+DepP+WithP) ->
			Cid ! {'withdraw',AccNo,Amount};
		true ->
			ok
	end,
	sendProbRequests(Cid,GetBalP,DepP,WithP,NoOfReq-1).

start(Master_PID,BankName,Clients,0) -> ok;
start(Master_PID,BankName,Clients,NoOfClients) ->
	ClientRequestsInfo = lists:nth(NoOfClients,Clients),
	DropRate = element(2,element(6,ClientRequestsInfo)),
	spawn(clientModule,client,[Master_PID,BankName,ClientRequestsInfo,0,0,0,0,DropRate]),
	start(Master_PID,BankName,Clients,NoOfClients-1).
