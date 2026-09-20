#pragma once

// The SDK's own constants, handed to Swift as functions. See module.modulemap
// for why they cannot be named directly in Swift. Nothing is defined here;
// every body is an SDK macro, and every symbol behind them is in libSystem on
// every iOS that has XPC at all.
//
// Keep only the ones the project uses — an accessor nobody calls is a line to
// maintain — and add one when a call site needs it.

#include <xpc/xpc.h>
#include <xpc/connection.h>

static inline xpc_type_t app_xpc_type_bool(void) { return XPC_TYPE_BOOL; }
static inline xpc_type_t app_xpc_type_connection(void) { return XPC_TYPE_CONNECTION; }
static inline xpc_type_t app_xpc_type_dictionary(void) { return XPC_TYPE_DICTIONARY; }
static inline xpc_type_t app_xpc_type_error(void) { return XPC_TYPE_ERROR; }
