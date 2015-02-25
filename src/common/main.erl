-module(main).
-export([start/1]).

start(Config) ->
	%%{ok, Log} = file:open("log", [write]),
	%%erlang:group_leader(Log, self()),
	error_logger:logfile({open, "../../logs/chainReplication.log"}),
	Master_PID = masterModule: start(),
	{ok, Terms} = file:consult(Config),
	%%reading from config file
	Tuple = lists:nth(1,Terms),
	NoOfBanks = element(2,element(1,Tuple)),
	Banks = element(2,element(2,Tuple)),
	Length = length(Banks),
	read(Master_PID,Banks,Length).
	
%%starting servers and clients
read(Master_PID,Banks,0) -> ok;
read(Master_PID,Banks,N) ->
	BankName = element(2,element(1,lists:nth(N,Banks))),
	NoOfServers = element(2,element(2,lists:nth(N,Banks))),
	Servers = element(2,element(4,lists:nth(N,Banks))),
	NoOfClients = element(2,element(3,lists:nth(N,Banks))),
	Clients = element(2,element(5,lists:nth(N,Banks))),
	serverModule: start(Master_PID,BankName,Servers,NoOfServers),
	receive
	after
		6000 ->
			true
	end,
	clientModule: start(Master_PID,BankName,Clients,NoOfClients),
	read(Master_PID,Banks,N-1).
