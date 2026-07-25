// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_BOT_H__
#define __SCHEMA_CODEGEN_BOT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
    double y;
    double vx;
    double vy;
    char* kind;
    double minX;
    double maxX;
    double baseY;
    double phaseMs;
    double speed;
    double lastTeleport;
} bot_t;

static const colyseus_field_t bot_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, x), NULL, NULL, NULL},
    {1, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, y), NULL, NULL, NULL},
    {2, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, vx), NULL, NULL, NULL},
    {3, "vy", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, vy), NULL, NULL, NULL},
    {4, "kind", COLYSEUS_FIELD_STRING, "string", offsetof(bot_t, kind), NULL, NULL, NULL},
    {5, "minX", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, minX), NULL, NULL, NULL},
    {6, "maxX", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, maxX), NULL, NULL, NULL},
    {7, "baseY", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, baseY), NULL, NULL, NULL},
    {8, "phaseMs", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, phaseMs), NULL, NULL, NULL},
    {9, "speed", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, speed), NULL, NULL, NULL},
    {10, "lastTeleport", COLYSEUS_FIELD_NUMBER, "number", offsetof(bot_t, lastTeleport), NULL, NULL, NULL}
};

static bot_t* bot_create(void) {
    bot_t* instance = calloc(1, sizeof(bot_t));
    return instance;
}

static void bot_destroy(colyseus_schema_t* schema) {
    bot_t* instance = (bot_t*)schema;
    if (instance->kind) free(instance->kind);
    free(instance);
}

static const colyseus_schema_vtable_t bot_vtable = {
    "Bot",
    sizeof(bot_t),
    (colyseus_schema_t* (*)(void))bot_create,
    bot_destroy,
    bot_fields,
    11
};

#endif
