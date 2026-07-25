// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_PLAYER_H__
#define __SCHEMA_CODEGEN_PLAYER_H__ 1

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
    uint8_t hue;
} player_t;

static const colyseus_field_t player_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, x), NULL, NULL, NULL},
    {1, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, y), NULL, NULL, NULL},
    {2, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, vx), NULL, NULL, NULL},
    {3, "vy", COLYSEUS_FIELD_NUMBER, "number", offsetof(player_t, vy), NULL, NULL, NULL},
    {4, "hue", COLYSEUS_FIELD_UINT8, "uint8", offsetof(player_t, hue), NULL, NULL, NULL}
};

static player_t* player_create(void) {
    player_t* instance = calloc(1, sizeof(player_t));
    return instance;
}

static void player_destroy(colyseus_schema_t* schema) {
    player_t* instance = (player_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t player_vtable = {
    "Player",
    sizeof(player_t),
    (colyseus_schema_t* (*)(void))player_create,
    player_destroy,
    player_fields,
    5
};

#endif
