/**
 * FreeRDP: A Remote Desktop Protocol Implementation
 * FreeRDP Proxy Server persist-bitmap-filter Module
 *
 * this module is designed to deactivate all persistent bitmap cache settings a
 * client might send.
 *
 * Copyright 2023 Armin Novak <anovak@thincast.com>
 * Copyright 2023 Thincast Technologies GmbH
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <map>
#include <memory>
#include <mutex>

#include <freerdp/server/proxy/proxy_modules_api.h>
#include <freerdp/server/proxy/proxy_context.h>

#include <freerdp/channels/drdynvc.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/utils/gfx.h>

#define TAG MODULE_TAG("persist-bitmap-filter")

static constexpr char plugin_name[] = "bitmap-filter";
static constexpr char plugin_desc[] =
    "this plugin deactivates and filters persistent bitmap cache.";

static const std::vector<std::string> plugin_static_intercept = { DRDYNVC_SVC_CHANNEL_NAME };
static const std::vector<std::string> plugin_dyn_intercept = { RDPGFX_DVC_CHANNEL_NAME };

class DynChannelState
{

  public:
	bool skip() const
	{
		return _toSkip != 0;
	}

	bool skip(size_t s)
	{
		if (s > _toSkip)
			_toSkip = 0;
		else
			_toSkip -= s;
		return skip();
	}

	size_t remaining() const
	{
		return _toSkip;
	}

	size_t total() const
	{
		return _totalSkipSize;
	}

	void setSkipSize(size_t len)
	{
		_toSkip = _totalSkipSize = len;
	}

	bool drop() const
	{
		return _drop;
	}

	void setDrop(bool d)
	{
		_drop = d;
	}

  private:
	size_t _toSkip = 0;
	size_t _totalSkipSize = 0;
	bool _drop = false;
};

class DynChannelStateMap
{
  public:
	std::map<std::string, DynChannelState> map;
	std::mutex mux;
};

static BOOL filter_client_pre_connect(proxyPlugin* plugin, proxyData* pdata, void* custom)
{
	WINPR_ASSERT(plugin);
	WINPR_ASSERT(pdata);
	WINPR_ASSERT(pdata->pc);
	WINPR_ASSERT(custom);

	auto settings = pdata->pc->context.settings;

	/* We do not want persistent bitmap cache to be used with proxy */
	return freerdp_settings_set_bool(settings, FreeRDP_BitmapCachePersistEnabled, FALSE);
}

static BOOL filter_dyn_channel_intercept_list(proxyPlugin* plugin, proxyData* pdata, void* arg)
{
	auto data = static_cast<proxyChannelToInterceptData*>(arg);

	WINPR_ASSERT(plugin);
	WINPR_ASSERT(pdata);
	WINPR_ASSERT(data);

	auto intercept = std::find(plugin_dyn_intercept.begin(), plugin_dyn_intercept.end(),
	                           data->name) != plugin_dyn_intercept.end();
	if (intercept)
		data->intercept = TRUE;
	return TRUE;
}

static BOOL filter_static_channel_intercept_list(proxyPlugin* plugin, proxyData* pdata, void* arg)
{
	auto data = static_cast<proxyChannelToInterceptData*>(arg);

	WINPR_ASSERT(plugin);
	WINPR_ASSERT(pdata);
	WINPR_ASSERT(data);

	auto intercept = std::find(plugin_static_intercept.begin(), plugin_static_intercept.end(),
	                           data->name) != plugin_static_intercept.end();
	if (intercept)
		data->intercept = TRUE;
	return TRUE;
}

static size_t drdynvc_cblen_to_bytes(UINT8 cbLen)
{
	switch (cbLen)
	{
		case 0:
			return 1;

		case 1:
			return 2;

		default:
			return 4;
	}
}

static UINT32 drdynvc_read_variable_uint(wStream* s, UINT8 cbLen)
{
	UINT32 val;

	switch (cbLen)
	{
		case 0:
			Stream_Read_UINT8(s, val);
			break;

		case 1:
			Stream_Read_UINT16(s, val);
			break;

		default:
			Stream_Read_UINT32(s, val);
			break;
	}

	return val;
}

static BOOL drdynvc_try_read_header(wStream* s, size_t& channelId, size_t& length)
{
	UINT8 value = 0;
	Stream_SetPosition(s, 0);
	if (Stream_GetRemainingLength(s) < 1)
		return FALSE;
	Stream_Read_UINT8(s, value);

	const UINT8 cmd = (value & 0xf0) >> 4;
	const UINT8 Sp = (value & 0x0c) >> 2;
	const UINT8 cbChId = (value & 0x03);

	switch (cmd)
	{
		case DATA_PDU:
		case DATA_FIRST_PDU:
			break;
		default:
			return FALSE;
	}

	const size_t channelIdLen = drdynvc_cblen_to_bytes(cbChId);
	if (Stream_GetRemainingLength(s) < channelIdLen)
		return FALSE;

	channelId = drdynvc_read_variable_uint(s, cbChId);
	length = Stream_Length(s);
	if (cmd == DATA_FIRST_PDU)
	{
		const size_t dataLen = drdynvc_cblen_to_bytes(Sp);
		if (Stream_GetRemainingLength(s) < dataLen)
			return FALSE;

		length = drdynvc_read_variable_uint(s, Sp);
	}

	return TRUE;
}

static BOOL filter_dyn_channel_intercept(proxyPlugin* plugin, proxyData* pdata, void* arg)
{
	auto data = static_cast<proxyDynChannelInterceptData*>(arg);

	WINPR_ASSERT(plugin);
	WINPR_ASSERT(pdata);
	WINPR_ASSERT(data);

	data->result = PF_CHANNEL_RESULT_PASS;
	if (!data->isBackData &&
	    (strncmp(data->name, RDPGFX_DVC_CHANNEL_NAME, ARRAYSIZE(RDPGFX_DVC_CHANNEL_NAME)) == 0))
	{
		const std::string sessionId = pdata->session_id;
		auto map = static_cast<DynChannelStateMap*>(plugin->custom);
		WINPR_ASSERT(map);

		std::lock_guard<std::mutex> lk(map->mux);
		if (map->map.find(sessionId) == map->map.end())
		{
			WLog_ERR(TAG, "[SessionID=%s][%s] missing custom data, aborting!", sessionId.c_str(),
			         plugin_name);
			return FALSE;
		}
		auto& state = map->map[sessionId];
		const size_t inputDataLength = Stream_Length(data->data);
		UINT16 cmdId = RDPGFX_CMDID_UNUSED_0000;

		if (!state.skip())
		{
			if (data->first)
			{
				const auto pos = Stream_GetPosition(data->data);

				size_t channelId = 0;
				size_t length = 0;
				if (drdynvc_try_read_header(data->data, channelId, length))
				{
					if (Stream_GetRemainingLength(data->data) >= 2)
					{
						Stream_Read_UINT16(data->data, cmdId);
						state.setSkipSize(length);
						state.setDrop(false);
					}
				}

				switch (cmdId)
				{
					case RDPGFX_CMDID_CACHEIMPORTOFFER:
						state.setDrop(true);
						break;
					default:
						break;
				}
				Stream_SetPosition(data->data, pos);
			}
		}

		if (state.skip())
		{
			state.skip(inputDataLength);
			if (state.drop())
			{
				WLog_WARN(TAG,
				          "[SessionID=%s][%s] dropping %s packet [total:%" PRIuz ", current:%" PRIuz
				          ", remaining: %" PRIuz "]",
				          pdata->session_id, plugin_name,
				          rdpgfx_get_cmd_id_string(RDPGFX_CMDID_CACHEIMPORTOFFER), state.total(),
				          inputDataLength, state.remaining());
				data->result = PF_CHANNEL_RESULT_DROP;
			}
		}
	}

	return TRUE;
}

static BOOL filter_plugin_unload(proxyPlugin* plugin)
{
	WINPR_ASSERT(plugin);

	/* Here we have to free up our custom data storage. */
	if (plugin)
		delete static_cast<DynChannelStateMap*>(plugin->custom);

	return TRUE;
}

static BOOL filter_server_session_started(proxyPlugin* plugin, proxyData* pdata, void*)
{
	WINPR_ASSERT(plugin);
	WINPR_ASSERT(pdata);

	const std::string sessionId = pdata->session_id;
	auto map = static_cast<DynChannelStateMap*>(plugin->custom);
	WINPR_ASSERT(map);

	std::lock_guard<std::mutex> lk(map->mux);
	map->map.emplace(sessionId, DynChannelState());
	return TRUE;
}

static BOOL filter_server_session_end(proxyPlugin* plugin, proxyData* pdata, void*)
{
	WINPR_ASSERT(plugin);
	WINPR_ASSERT(pdata);

	const std::string sessionId = pdata->session_id;
	auto map = static_cast<DynChannelStateMap*>(plugin->custom);
	WINPR_ASSERT(map);

	std::lock_guard<std::mutex> lk(map->mux);
	map->map.erase(sessionId);
	return TRUE;
}

#ifdef __cplusplus
extern "C"
{
#endif
	FREERDP_API BOOL proxy_module_entry_point(proxyPluginsManager* plugins_manager, void* userdata);
#ifdef __cplusplus
}
#endif

BOOL proxy_module_entry_point(proxyPluginsManager* plugins_manager, void* userdata)
{
	proxyPlugin plugin = {};

	plugin.name = plugin_name;
	plugin.description = plugin_desc;
	plugin.PluginUnload = filter_plugin_unload;

	plugin.ServerSessionStarted = filter_server_session_started;
	plugin.ServerSessionEnd = filter_server_session_end;

	plugin.ClientPreConnect = filter_client_pre_connect;

	plugin.StaticChannelToIntercept = filter_static_channel_intercept_list;
	plugin.DynChannelToIntercept = filter_dyn_channel_intercept_list;
	plugin.DynChannelIntercept = filter_dyn_channel_intercept;

	plugin.custom = new DynChannelStateMap();
	if (!plugin.custom)
		return FALSE;
	plugin.userdata = userdata;

	return plugins_manager->RegisterPlugin(plugins_manager, &plugin);
}
