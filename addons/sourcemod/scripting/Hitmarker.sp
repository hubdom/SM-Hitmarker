#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <clientprefs>
#include <multicolors>
#include <dhooks>
#include <outputinfo>

#pragma newdecls required
#pragma	semicolon 1

#define SPECMODE_NONE           0
#define SPECMODE_FIRSTPERSON    4
#define SPECMODE_THIRDPERSON    5
#define SPECMODE_FREELOOK       6

#define MAX_EDICTS 2048
bool g_bHasOutputs[MAX_EDICTS];
Handle g_hCookie_ShowBossHitmarker;
Handle g_hCookie_ShowZombieHitmarker;
Handle g_hCookie_HitmarkerSound;
Handle g_hCookie_HitmarkerSoundVolume;
Handle g_hCookie_HitmarkerSkin;
ConVar g_hCVar_Debug;
bool g_bLate;

enum struct PlayerInfo{
	bool bShowBossHitmarker;
	bool bShowZombieHitmarker;
	bool bHitmarkerSound;
	int iHitmarkerSoundVolume;
	int iHitmarkerSkin;
	Handle hTimer;

	int Reset() {
		this.bShowBossHitmarker = false;
		this.bShowZombieHitmarker = false;
		this.bHitmarkerSound = false;
		this.iHitmarkerSoundVolume = 100;
		this.iHitmarkerSkin = 0;

	}
}
PlayerInfo g_aPlayerInfo[MAXPLAYERS+1];


enum struct HitmarkerSkin{
	char sPath[PLATFORM_MAX_PATH];
	char sName[PLATFORM_MAX_PATH];

	int Reset() {
		this.sPath = "";
		this.sName = "";
	}
}
#define MAXIMUMSKINS 6
HitmarkerSkin g_aHitmarkerSkin[MAXIMUMSKINS];

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public Plugin myinfo =
{
	name         = "Hitmarker",
	description  = "Players can enable or disable their hitmarkers while shooting zombies or bosses",
	version      = "3.2",
	url         = "https://github.com/hubdom"
};

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] sError, int errorSize)
{
	g_bLate = bLate;
	return APLRes_Success;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnPluginStart()
{
	Handle g_hOnTakeDamageDetour;
	Handle hGameData = LoadGameConfigFile("Hitmarker.games");
	if(!hGameData)
		SetFailState("Failed to load Hitmarker gamedata.");

	g_hOnTakeDamageDetour = DHookCreateFromConf(hGameData, "CBaseEntity__OnTakeDamage");
	if(!g_hOnTakeDamageDetour)
		SetFailState("Failed to setup detour for CBaseEntity__OnTakeDamage");

	delete hGameData;

	if(!DHookEnableDetour(g_hOnTakeDamageDetour, true, Detour_OnTakeDamage))
		SetFailState("Failed to detour CBaseEntity__OnTakeDamage.");

	g_hCookie_ShowBossHitmarker = RegClientCookie("hitmarker_boss", "", CookieAccess_Private);
	g_hCookie_ShowZombieHitmarker = RegClientCookie("hitmarker_zombie", "", CookieAccess_Private);
	g_hCookie_HitmarkerSound = RegClientCookie("hitmarker_sound", "", CookieAccess_Private);
	g_hCookie_HitmarkerSoundVolume = RegClientCookie("hitmarker_sound_volume", "", CookieAccess_Private);
	g_hCookie_HitmarkerSkin = RegClientCookie("hitmarker_skin", "", CookieAccess_Private);

	g_hCVar_Debug = CreateConVar("sm_hitmarker_debug", "0", "", FCVAR_NONE, true, 0.0, true, 1.0);
	AutoExecConfig();

	RegConsoleCmd("sm_hm", OnHitmarkerSettings);
	RegConsoleCmd("sm_hitmarker", OnHitmarkerSettings);
	RegConsoleCmd("sm_bhm", OnToggleBossHitmarker);
	RegConsoleCmd("sm_zhm", OnToggleZombieHitmarker);
	RegConsoleCmd("sm_hmsound", OnToggleHitmarkerSound);

	SetCookieMenuItem(MenuHandler_CookieMenu, 0, "Hitmarker");

	HookEvent("player_hurt", OnClientHurt);

	if (g_bLate)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsValidClient(i) && AreClientCookiesCached(i))
				OnClientCookiesCached(i);
		}
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnMapStart()
{
	for (int i = 0; i < MAXIMUMSKINS; i++)
		g_aHitmarkerSkin[i].Reset();

	char sConfigFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sConfigFile, sizeof(sConfigFile), "configs/Hitmarkers.cfg");

	if (!FileExists(sConfigFile))
		SetFailState("Could not find: \"%s\"", sConfigFile);

	KeyValues Hitmarkers = new KeyValues("Hitmarkers");

	if (!Hitmarkers.ImportFromFile(sConfigFile))
	{
		delete Hitmarkers;
		SetFailState("ImportFromFile() failed!");
	}

	if (!Hitmarkers.GotoFirstSubKey())
	{
		delete Hitmarkers;
		SetFailState("Unable to goto first sub key in: \"%s\"", sConfigFile);
	}

	int i = 0;
	do
	{
		char sPath[PLATFORM_MAX_PATH];
		Hitmarkers.GetString("Path", sPath, sizeof(sPath), "error");
		if (StrEqual(sPath, "error"))
		{
			delete Hitmarkers;
			SetFailState("Unable to read Path");
		}

		char sName[32];
		Hitmarkers.GetString("Name", sName, sizeof(sName), "error");
		if (StrEqual(sName, "error"))
		{
			delete Hitmarkers;
			SetFailState("Unable to read Name");
		}

		char sBuffer[PLATFORM_MAX_PATH];

		Format(sBuffer, sizeof(sBuffer), "materials/%s.vmt", sPath);
		PrecacheGeneric(sBuffer, true);
		AddFileToDownloadsTable(sBuffer);

		Format(sBuffer, sizeof(sBuffer), "materials/%s.vtf", sPath);
		PrecacheGeneric(sBuffer, true);
		AddFileToDownloadsTable(sBuffer);

		g_aHitmarkerSkin[i].sPath = sPath;
		g_aHitmarkerSkin[i].sName = sName;
		i++;
	} while(Hitmarkers.GotoNextKey());
	delete Hitmarkers;

	PrecacheSound("hitmarker/hm_v3.mp3");
	AddFileToDownloadsTable("sound/hitmarker/hm_v3.mp3");
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnClientCookiesCached(int client)
{
	char sBuffer[PLATFORM_MAX_PATH];

	GetClientCookie(client, g_hCookie_ShowBossHitmarker, sBuffer, sizeof(sBuffer));
	if (sBuffer[0])
		g_aPlayerInfo[client].bShowBossHitmarker = true;
	else
		g_aPlayerInfo[client].bShowBossHitmarker = false;

	GetClientCookie(client, g_hCookie_ShowZombieHitmarker, sBuffer, sizeof(sBuffer));
	if (sBuffer[0])
		g_aPlayerInfo[client].bShowZombieHitmarker = true;
	else
		g_aPlayerInfo[client].bShowZombieHitmarker = false;

	GetClientCookie(client, g_hCookie_HitmarkerSound, sBuffer, sizeof(sBuffer));
	if (sBuffer[0])
		g_aPlayerInfo[client].bHitmarkerSound = true;
	else
		g_aPlayerInfo[client].bHitmarkerSound = false;

	GetClientCookie(client, g_hCookie_HitmarkerSoundVolume, sBuffer, sizeof(sBuffer));
	if (sBuffer[0])
		g_aPlayerInfo[client].iHitmarkerSoundVolume = StringToInt(sBuffer);
	else
		g_aPlayerInfo[client].iHitmarkerSoundVolume = 100;

	GetClientCookie(client, g_hCookie_HitmarkerSkin, sBuffer, sizeof(sBuffer));
	if (sBuffer[0])
	{
		for (int i = 0; i < MAXIMUMSKINS; i++)
		{
			if (!g_aHitmarkerSkin[i].sPath[0])
				break;

			if (StrEqual(g_aHitmarkerSkin[i].sPath, sBuffer))
			{
				g_aPlayerInfo[client].iHitmarkerSkin = i;
				break;
			}
		}
	}
	else
		g_aPlayerInfo[client].iHitmarkerSkin = 0;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnClientDisconnect(int client)
{
	g_aPlayerInfo[client].Reset();
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public Action OnHitmarkerSettings(int client, int args)
{
	ShowSettingsMenu(client);
	return Plugin_Handled;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public Action OnToggleBossHitmarker(int client, int args)
{
	ToggleBossHitmarker(client);
	return Plugin_Handled;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ToggleBossHitmarker(int client)
{
	g_aPlayerInfo[client].bShowBossHitmarker = !g_aPlayerInfo[client].bShowBossHitmarker;
	SetClientCookie(client, g_hCookie_ShowBossHitmarker, g_aPlayerInfo[client].bShowBossHitmarker ? "1" : "");

	CPrintToChat(client, "{cyan}[Hitmarker] {white}%s.", g_aPlayerInfo[client].bShowBossHitmarker ? "Boss Hitmarker Enabled" : "Boss Hitmarker Disabled");

	if (g_aPlayerInfo[client].bShowBossHitmarker)
		ShowOverlay(client, 2.0);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public Action OnToggleZombieHitmarker(int client, int args)
{
	ToggleZombieHitmarker(client);
	return Plugin_Handled;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ToggleZombieHitmarker(int client)
{
	g_aPlayerInfo[client].bShowZombieHitmarker = !g_aPlayerInfo[client].bShowZombieHitmarker;
	SetClientCookie(client, g_hCookie_ShowZombieHitmarker, g_aPlayerInfo[client].bShowZombieHitmarker ? "1" : "");

	CPrintToChat(client, "{cyan}[Hitmarker] {white}%s.", g_aPlayerInfo[client].bShowZombieHitmarker ? "Zombie Hitmarker Enabled" : "Zombie Hitmarker Disabled");

	if (g_aPlayerInfo[client].bShowZombieHitmarker)
		ShowOverlay(client, 2.0);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public Action OnToggleHitmarkerSound(int client, int args)
{
	ToggleHitmarkerSound(client);
	return Plugin_Handled;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ToggleHitmarkerSound(int client)
{
	g_aPlayerInfo[client].bHitmarkerSound = !g_aPlayerInfo[client].bHitmarkerSound;
	SetClientCookie(client, g_hCookie_HitmarkerSound, g_aPlayerInfo[client].bHitmarkerSound ? "1" : "");

	CPrintToChat(client, "{cyan}[Hitmarker] {white}%s.", g_aPlayerInfo[client].bHitmarkerSound ? "Hitmarker Sound Enabled" : "Hitmarker Sound Disabled");

	if (g_aPlayerInfo[client].bHitmarkerSound)
		ShowOverlay(client, 2.0);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ToggleHitmarkerSoundVolume(int client)
{
	g_aPlayerInfo[client].iHitmarkerSoundVolume += 25;

	if(g_aPlayerInfo[client].iHitmarkerSoundVolume > 100)
		g_aPlayerInfo[client].iHitmarkerSoundVolume = 25;

	char sBuffer[16];
	IntToString(g_aPlayerInfo[client].iHitmarkerSoundVolume, sBuffer, sizeof(sBuffer));

	SetClientCookie(client, g_hCookie_HitmarkerSoundVolume, sBuffer);

	ShowOverlay(client, 2.0);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ToggleHitmarkerSkin(int client)
{
	g_aPlayerInfo[client].iHitmarkerSkin++;

	if (StrEqual(g_aHitmarkerSkin[g_aPlayerInfo[client].iHitmarkerSkin].sPath, ""))
		g_aPlayerInfo[client].iHitmarkerSkin = 0;

	SetClientCookie(client, g_hCookie_HitmarkerSkin, g_aHitmarkerSkin[g_aPlayerInfo[client].iHitmarkerSkin].sPath);

	ShowOverlay(client, 2.0);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ShowSettingsMenu(int client)
{
	Menu menu = new Menu(MenuHandler_MainMenu);

	menu.SetTitle("Hitmarker Settings", client);

	char sBuffer[128];

	Format(sBuffer, sizeof(sBuffer), "Boss Hitmarker: %s", g_aPlayerInfo[client].bShowBossHitmarker ? "Enabled" : "Disabled");
	menu.AddItem("0", sBuffer);

	Format(sBuffer, sizeof(sBuffer), "Zombie Hitmarker: %s", g_aPlayerInfo[client].bShowZombieHitmarker ? "Enabled" : "Disabled");
	menu.AddItem("1", sBuffer);

	Format(sBuffer, sizeof(sBuffer), "Hitmarker Sound: %s", g_aPlayerInfo[client].bHitmarkerSound ? "Enabled" : "Disabled");
	menu.AddItem("2", sBuffer);

	Format(sBuffer, sizeof(sBuffer), "Hitmarker Sound Volume: %d\%", g_aPlayerInfo[client].iHitmarkerSoundVolume);
	menu.AddItem("3", sBuffer);

	Format(sBuffer, sizeof(sBuffer), "Hitmarker Skin: %s", g_aHitmarkerSkin[g_aPlayerInfo[client].iHitmarkerSkin].sName);
	menu.AddItem("4", sBuffer);

	menu.ExitBackButton = true;

	menu.Display(client, MENU_TIME_FOREVER);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void MenuHandler_CookieMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	switch(action)
	{
		case(CookieMenuAction_DisplayOption):
		{
			Format(buffer, maxlen, "Hitmarker", client);
		}
		case(CookieMenuAction_SelectOption):
		{
			ShowSettingsMenu(client);
		}
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public int MenuHandler_MainMenu(Menu menu, MenuAction action, int client, int selection)
{
	switch(action)
	{
		case(MenuAction_Select):
		{
			switch(selection)
			{
				case(0): ToggleBossHitmarker(client);
				case(1): ToggleZombieHitmarker(client);
				case(2): ToggleHitmarkerSound(client);
				case(3): ToggleHitmarkerSoundVolume(client);
				case(4): ToggleHitmarkerSkin(client);
			}

			ShowSettingsMenu(client);
		}
		case(MenuAction_Cancel):
		{
			ShowCookieMenu(client);
		}
		case(MenuAction_End):
		{
			delete menu;
		}
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnEntitySpawned(int Entity, const char[] sClassname)
{
	int ent = EntRefToEntIndex(Entity);

	if (0 < ent < MAX_EDICTS)
	{
		if ((GetOutputCount(ent, "m_OnDamaged") > 0) || (GetOutputCount(ent, "m_OnHealthChanged") > 0))
			g_bHasOutputs[ent] = true;
		else
			g_bHasOutputs[ent] = false;
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public MRESReturn Detour_OnTakeDamage(int entity, Handle hReturn, Handle hParams)
{
	//https://github.com/alliedmodders/hl2sdk/blob/css/game/shared/takedamageinfo.h#L115
	int iHealth = GetEntProp(entity, Prop_Data, "m_iHealth");
	int client = DHookGetParamObjectPtrVar(hParams, 1, 3*(3*4) + 0, ObjectValueType_Ehandle);

	if (g_hCVar_Debug.BoolValue)
	{
		float dmg = DHookGetParamObjectPtrVar(hParams, 1, 48, ObjectValueType_Float);
		PrintToChatAll("Detour_OnTakeDamage: ent: %d; client: %d; m_iHealth: %d; output: %d; dmg: %f", entity, client, iHealth, g_bHasOutputs[entity], dmg);
	}

	if (!iHealth && !g_bHasOutputs[entity])
		return MRES_Ignored;

	if (!IsValidClient(client))
		return MRES_Ignored;

	if (g_aPlayerInfo[client].bShowBossHitmarker)
		ShowOverlay(client);

	for (int spec = 1; spec <= MaxClients; spec++)
	{
		if (!IsClientInGame(spec) || !IsClientObserver(spec) || !g_aPlayerInfo[spec].bShowBossHitmarker)
			continue;

		int specMode   = GetClientSpectatorMode(spec);
		int specTarget = GetClientSpectatorTarget(spec);

		if ((specMode == SPECMODE_FIRSTPERSON) && specTarget == client)
			ShowOverlay(spec);
	}

	return MRES_Ignored;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnClientHurt(Event hEvent, const char[] sEvent, bool bDontBroadcast)
{
	int client = GetClientOfUserId(hEvent.GetInt("attacker"));
	int victim = GetClientOfUserId(hEvent.GetInt("userid"));

	if (client < 1 || client > MaxClients || victim < 1 || victim > MaxClients)
		return;

	if (client == victim || GetClientTeam(client) == CS_TEAM_T)
		return;

	if (g_aPlayerInfo[client].bShowZombieHitmarker)
		ShowOverlay(client);

	for (int spec = 1; spec <= MaxClients; spec++)
	{
		if (!IsClientInGame(spec) || !IsClientObserver(spec) || !g_aPlayerInfo[spec].bShowZombieHitmarker)
			continue;

		int specMode   = GetClientSpectatorMode(spec);
		int specTarget = GetClientSpectatorTarget(spec);

		if (specMode == SPECMODE_FIRSTPERSON && specTarget == client)
			ShowOverlay(spec);
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
void ShowOverlay(int client, float fTime = 0.3)
{
	if (g_aPlayerInfo[client].bHitmarkerSound)
	{
		float fVolume = g_aPlayerInfo[client].iHitmarkerSoundVolume / 100.0;
		EmitSoundToClient(client, "hitmarker/hm_v3.mp3", .volume=fVolume);
	}

	if (g_aPlayerInfo[client].hTimer != null)
	{
		delete g_aPlayerInfo[client].hTimer;
		g_aPlayerInfo[client].hTimer = null;
	}
	ClientCommand(client, "r_screenoverlay \"%s\"", g_aHitmarkerSkin[g_aPlayerInfo[client].iHitmarkerSkin].sPath);
	g_aPlayerInfo[client].hTimer = CreateTimer(fTime, ClearOverlay, client);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public Action ClearOverlay(Handle timer, int client)
{
	g_aPlayerInfo[client].hTimer = null;
	if (IsClientConnected(client))
		ClientCommand(client, "r_screenoverlay \"\"");
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
stock int IsValidClient(int client, bool nobots = true)
{
	if (client <= 0 || client > MaxClients || !IsClientConnected(client) || (nobots && IsFakeClient(client)))
		return false;

	return IsClientInGame(client);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
int GetClientSpectatorMode(int client)
{
	return GetEntProp(client, Prop_Send, "m_iObserverMode");
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
int GetClientSpectatorTarget(int client)
{
	return GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
}
