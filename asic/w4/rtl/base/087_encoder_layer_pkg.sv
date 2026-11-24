package encoder_layer_pkg;
    localparam logic[31:0] STATE_A=32'h80014000,STATE_B=32'h8001c000,
        PARAMETERS=32'h80044000,GELU=32'h80060000,EXP=32'h80064004;
    typedef struct packed {
        logic[31:0] task_id,epoch;
        logic[3:0] layer;
        logic[31:0] x,y,parameters,parameter_bytes,gelu,exp;
    } command_t;
    typedef struct packed {logic valid,read;logic[31:0] address,data;} request_t;
    typedef struct packed {logic valid,error;logic[31:0] data;} response_t;
    typedef struct packed {logic valid;logic[2:0] kind;logic[14:0] address;logic[63:0] data;} load_t;
    typedef struct packed {logic valid;logic[31:0] data;logic[6:0] row;logic[7:0] col;logic[3:0] layer;} value_t;
endpackage
