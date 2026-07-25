// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_MOVEINPUT_H__
#define __SCHEMA_CODEGEN_MOVEINPUT_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    int8_t moveX;
    int8_t moveY;
} move_input_t;

static const colyseus_field_t move_input_fields[] = {
    {0, "moveX", COLYSEUS_FIELD_INT8, "int8", offsetof(move_input_t, moveX), NULL, NULL, NULL},
    {1, "moveY", COLYSEUS_FIELD_INT8, "int8", offsetof(move_input_t, moveY), NULL, NULL, NULL}
};

static move_input_t* move_input_create(void) {
    move_input_t* instance = calloc(1, sizeof(move_input_t));
    return instance;
}

static void move_input_destroy(colyseus_schema_t* schema) {
    move_input_t* instance = (move_input_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t move_input_vtable = {
    "MoveInput",
    sizeof(move_input_t),
    (colyseus_schema_t* (*)(void))move_input_create,
    move_input_destroy,
    move_input_fields,
    2
};

#endif
