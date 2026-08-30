//
//  WiresharkIPDisplayFilterPlugin.c
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

// Keep Wireshark's official IP display-filter functions available in the plugin-free embedded build.
#define plugin_register TCPViewerWiresharkIPDisplayFilterPluginRegister
#define plugin_describe TCPViewerWiresharkIPDisplayFilterPluginDescribe
#define plugin_version TCPViewerWiresharkIPDisplayFilterPluginVersion
#define plugin_want_major TCPViewerWiresharkIPDisplayFilterPluginWantMajor
#define plugin_want_minor TCPViewerWiresharkIPDisplayFilterPluginWantMinor
#include "../../Vendor/Wireshark/plugins/epan/dfilter/ipaddr/ipaddr.c"
