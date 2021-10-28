#include <sourcemod>
#include <clientprefs>
#include <tf2_stocks>
#include <sdkhooks>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

#define TF_MAXPLAYERS		33

#define GHOST_COLOR_RED		{ 159, 55, 34, 255 }
#define GHOST_COLOR_BLUE	{ 76, 109, 129, 255 }

#define GHOST_MODEL_RED 	"models/props_halloween/ghost_no_hat_red.mdl"
#define GHOST_MODEL_BLUE	"models/props_halloween/ghost_no_hat.mdl"

#define GHOST_SPEED 		375.0 // -20% in TFCond_SwimmingNoEffects (300)

enum
{
	State_Ignore,	// Ignored
	State_Ready,	// Ready to become ghost
	State_Ghost		// Ghost
}

int g_iPlayerState[TF_MAXPLAYERS + 1];
int g_iPlayerGhostTarget[TF_MAXPLAYERS + 1];
Cookie g_hGhostCookie;

public Plugin myinfo =
{
	name = "[TF2] Ghost Mode",
	author = "Jughead",
	version = "1.2",
	url = "https://steamcommunity.com/id/jugheadq"
};

public void OnPluginStart()
{
	g_hGhostCookie = new Cookie("ghostmode_preference", "", CookieAccess_Private);
	RegConsoleCmd("sm_ghost", Command_Ghost, "Turn on/off ghostmode");

	AddCommandListener(CL_Voicemenu, "voicemenu");
	AddCommandListener(CL_Joinclass, "joinclass");
	AddCommandListener(CL_Joinclass, "join_class");

	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", Event_PlayerDeath);

	GameData_Init();

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientPutInServer(i);
}

public void OnMapStart()
{
	PrecacheModel(GHOST_MODEL_RED, true);
	PrecacheModel(GHOST_MODEL_BLUE, true);
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			Client_CancelGhostMode(i);
}

public void OnClientPutInServer(int iClient)
{
	g_iPlayerState[iClient] = State_Ignore;
	SDKHook(iClient, SDKHook_PreThink, Hook_PreThink);
	SDKHook(iClient, SDKHook_SetTransmit, Hook_SetTransmit);
}

public MRESReturn DHook_PassEntityFilter(DHookReturn ret, DHookParam params)
{
	if (params.IsNull(1) || params.IsNull(2))
		return MRES_Ignored;

	int iEntity1 = params.Get(1);
	if (0 < iEntity1 <= MaxClients && IsClientInGhostMode(iEntity1))
	{
		ret.Value = false;
		return MRES_Supercede;
	}

	int iEntity2 = params.Get(2);
	if (0 < iEntity2 <= MaxClients && IsClientInGhostMode(iEntity2))
	{
		ret.Value = false;
		return MRES_Supercede;
	}

	return MRES_Ignored;
}

public void Hook_PreThink(int iClient)
{
	if (IsClientInGhostMode(iClient) && GetEntProp(iClient, Prop_Send, "m_nForceTauntCam") == 1)
		SetEntProp(iClient, Prop_Send, "m_nForceTauntCam", 2);
}

public Action Hook_SetTransmit(int iClient, int iOther)
{
	// Transmit on round end
	if (GameRules_GetRoundState() == RoundState_TeamWin)
		return Plugin_Continue;

	// Don't transmit to non-ghost players
	if (iOther != iClient && IsClientInGhostMode(iClient) && !IsClientInGhostMode(iOther))
		return Plugin_Handled;

	return Plugin_Continue;
}

public Action Command_Ghost(int iClient, int iArgc)
{
	if (iClient == 0)
		return Plugin_Handled;

	if (Cookie_Get(iClient))
	{
		Cookie_Set(iClient, "0");
		PrintToChat(iClient, "\x07E17100[SM] Ghost mode disabled");
		Client_CancelGhostMode(iClient);
	}
	else
	{
		Cookie_Set(iClient, "1");
		PrintToChat(iClient, "\x07E19F00[SM] Ghost mode enabled");

		if (IsActiveRound() && !IsPlayerAlive(iClient))
			CreateTimer(0.1, Timer_Respawn, GetClientUserId(iClient), TIMER_FLAG_NO_MAPCHANGE);
	}

	return Plugin_Handled;
}

public Action CL_Voicemenu(int iClient, const char[] sCommand, int iArgc)
{
	if (!IsClientInGhostMode(iClient))
		return Plugin_Continue;

	Client_SetNextGhostTarget(iClient);
	return Plugin_Handled;
}

public Action CL_Joinclass(int iClient, const char[] sCommand, int iArgc)
{
	if (iArgc < 1 || !IsClientInGhostMode(iClient))
		return Plugin_Continue;

	char sClass[24];
	GetCmdArg(1, sClass, sizeof(sClass));

	TFClassType class = TF2_GetClass(sClass);
	if (class != TFClass_Unknown)
		SetEntProp(iClient, Prop_Send, "m_iDesiredPlayerClass", view_as<int>(class));

	return Plugin_Handled;
}

public void Event_PlayerSpawn(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	if (iClient <= 0 || iClient > MaxClients || !IsClientInGame(iClient))
		return;

	Client_SetGhostMode(iClient, (IsActiveRound() && g_iPlayerState[iClient] == State_Ready) ? true : false);
}

public void Event_PlayerDeath(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	if (iClient <= 0 || iClient > MaxClients || !IsClientInGame(iClient))
		return;

	if (hEvent.GetInt("death_flags") & TF_DEATHFLAG_DEADRINGER)
		return;

	if (IsActiveRound() && Cookie_Get(iClient))
		CreateTimer(0.1, Timer_Respawn, GetClientUserId(iClient), TIMER_FLAG_NO_MAPCHANGE);
}

void Client_CancelGhostMode(int iClient)
{
	if (!IsClientInGhostMode(iClient))
		return;

	Client_SetGhostMode(iClient, false);
	SetEntProp(iClient, Prop_Send, "m_lifeState", 0);
	SetEntProp(iClient, Prop_Send, "m_nForceTauntCam", 0);

	ForcePlayerSuicide(iClient);
}

void Client_SetGhostMode(int iClient, bool bState)
{
	g_iPlayerGhostTarget[iClient] = INVALID_ENT_REFERENCE;
	g_iPlayerState[iClient] = bState ? State_Ghost : State_Ignore;
	SetEntProp(iClient, Prop_Send, "m_CollisionGroup", bState ? 1 : 5);

	if (bState)
	{
		TF2_AddCondition(iClient, TFCond_SwimmingNoEffects);
		SetEntProp(iClient, Prop_Send, "m_lifeState", 2);
		SetEntProp(iClient, Prop_Send, "m_iHideHUD", 8);
		SetEntProp(iClient, Prop_Send, "m_iClass", view_as<int>(TFClass_Spy)); // allow see enemy health

		SetVariantString(TF2_GetClientTeam(iClient) == TFTeam_Red ? GHOST_MODEL_RED : GHOST_MODEL_BLUE);
		AcceptEntityInput(iClient, "SetCustomModel");

		int iColor[4]; iColor = TF2_GetClientTeam(iClient) == TFTeam_Red ? GHOST_COLOR_RED : GHOST_COLOR_BLUE;
		SetEntityRenderColor(iClient, iColor[0], iColor[1], iColor[2], iColor[3]);

		Client_SetNextGhostTarget(iClient);
		CreateTimer(0.1, Timer_PostGhostMode, GetClientUserId(iClient), TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		SetVariantString("");
		AcceptEntityInput(iClient, "SetCustomModel");
		SetEntityRenderColor(iClient, 255, 255, 255, 255);
	}
}

public Action Timer_PostGhostMode(Handle hTimer, any userid)
{
	int iClient = GetClientOfUserId(userid);
	if (iClient <= 0 || iClient > MaxClients || !IsClientInGame(iClient) || !IsClientInGhostMode(iClient))
		return Plugin_Continue;

	int iEntity = MaxClients + 1;
	while ((iEntity = FindEntityByClassname(iEntity, "tf_wearable")) > MaxClients)
	{
		if (GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity") == iClient)
			TF2_RemoveWearable(iClient, iEntity);
	}

	iEntity = MaxClients + 1;
	while ((iEntity = FindEntityByClassname(iEntity, "tf_powerup_bottle")) > MaxClients)
	{
		if (GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity") == iClient)
			AcceptEntityInput(iEntity, "Kill");
	}

	iEntity = MaxClients + 1;
	while ((iEntity = FindEntityByClassname(iEntity, "tf_weapon_spellbook")) > MaxClients)
	{
		if (GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity") == iClient)
			AcceptEntityInput(iEntity, "Kill");
	}

	TF2_RemoveAllWeapons(iClient);
	SetEntProp(iClient, Prop_Send, "m_nForceTauntCam", 2);
	SetEntPropFloat(iClient, Prop_Send, "m_flMaxspeed", GHOST_SPEED);
	return Plugin_Continue;
}

public Action Timer_Respawn(Handle hTimer, any userid)
{
	int iClient = GetClientOfUserId(userid);
	if (iClient <= 0 || iClient > MaxClients || !IsClientInGame(iClient))
		return Plugin_Continue;

	if (IsActiveRound() && TF2_GetClientTeam(iClient) >= TFTeam_Red)
	{
		g_iPlayerState[iClient] = State_Ready;
		TF2_RespawnPlayer(iClient);
	}
	else
		g_iPlayerState[iClient] = State_Ignore;

	return Plugin_Continue;
}

void Client_SetNextGhostTarget(int iClient)
{
	int iLastTarget = EntRefToEntIndex(g_iPlayerGhostTarget[iClient]);
	int iNextTarget = -1, iFirstTarget = -1;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsClientInGhostMode(i) || !IsPlayerAlive(i))
			continue;

		if (iFirstTarget == -1)
			iFirstTarget = i;

		if (i > iLastTarget) 
		{
			iNextTarget = i;
			break;
		}
	}

	int iTarget = (0 < iNextTarget <= MaxClients && IsClientInGame(iNextTarget)) ? iNextTarget : iFirstTarget;
	if (0 < iTarget <= MaxClients && IsClientInGame(iTarget))
	{
		g_iPlayerGhostTarget[iClient] = EntIndexToEntRef(iTarget);

		float flPos[3], flAng[3], flVel[3];
		GetClientAbsOrigin(iTarget, flPos);
		GetClientEyeAngles(iTarget, flAng);
		GetEntPropVector(iTarget, Prop_Data, "m_vecAbsVelocity", flVel);
		TeleportEntity(iClient, flPos, flAng, flVel);
	}
}

bool IsClientInGhostMode(int iClient)
{
	return g_iPlayerState[iClient] == State_Ghost;
}

bool IsActiveRound()
{
	RoundState state = GameRules_GetRoundState();
	return state == RoundState_RoundRunning || state == RoundState_Stalemate;
}

bool Cookie_Get(int iClient)
{
	char sValue[8];
	g_hGhostCookie.Get(iClient, sValue, sizeof(sValue));
	if (!sValue[0] || StringToInt(sValue))
		return true;

	return false;
}

void Cookie_Set(int iClient, const char[] sValue)
{
	g_hGhostCookie.Set(iClient, sValue);
}

void GameData_Init()
{
	GameData hGameData = new GameData("ghostmode");
	if (!hGameData)
		SetFailState("Could not find ghostmode.txt gamedata!");

	DynamicDetour detour = DynamicDetour.FromConf(hGameData, "PassEntityFilter");
	if (!detour.Enable(Hook_Post, DHook_PassEntityFilter))
		LogError("Failed to detour \"PassEntityFilter\".");

	delete hGameData;
}