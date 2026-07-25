// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_MOVESTATE_H__
#define __SCHEMA_CODEGEN_MOVESTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "player.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
} move_state_t;

static const colyseus_field_t move_state_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(move_state_t, players), &player_vtable, NULL, NULL}
};

static move_state_t* move_state_create(void) {
    move_state_t* instance = calloc(1, sizeof(move_state_t));
    return instance;
}

static void move_state_destroy(colyseus_schema_t* schema) {
    move_state_t* instance = (move_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t move_state_vtable = {
    "MoveState",
    sizeof(move_state_t),
    (colyseus_schema_t* (*)(void))move_state_create,
    move_state_destroy,
    move_state_fields,
    1
};

#endif
