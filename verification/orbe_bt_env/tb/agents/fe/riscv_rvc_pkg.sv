// RV64C decompressor used by the FE agent before presenting instructions to BE.
package riscv_rvc_pkg;

  function automatic logic [31:0] enc_i(
    input logic [6:0] opcode, input logic [2:0] funct3,
    input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm
  );
    return {imm, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_r(
    input logic [6:0] funct7, input logic [4:0] rs2,
    input logic [4:0] rs1, input logic [2:0] funct3,
    input logic [4:0] rd, input logic [6:0] opcode
  );
    return {funct7, rs2, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_s(
    input logic [6:0] opcode, input logic [2:0] funct3,
    input logic [4:0] rs1, input logic [4:0] rs2, input logic [11:0] imm
  );
    return {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
  endfunction

  function automatic logic [31:0] enc_b(
    input logic [2:0] funct3, input logic [4:0] rs1,
    input logic [4:0] rs2, input logic [12:0] imm
  );
    return {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], 7'b1100011};
  endfunction

  function automatic logic [31:0] enc_u(
    input logic [4:0] rd, input logic [19:0] imm
  );
    return {imm, rd, 7'b0110111};
  endfunction

  function automatic logic [31:0] enc_j(
    input logic [4:0] rd, input logic [20:0] imm
  );
    return {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
  endfunction

  function automatic logic [31:0] rvc_decompress_rv64(
    input logic [15:0] c, output bit valid
  );
    logic [4:0] rd;
    logic [4:0] rs1p;
    logic [4:0] rs2;
    logic [4:0] rdp;
    logic [11:0] imm_i;
    logic [12:0] imm_b;
    logic [19:0] imm_u;
    logic [20:0] imm_j;

    rd = c[11:7];
    rs1p = {2'b01, c[9:7]};
    rs2 = c[6:2];
    rdp = {2'b01, c[4:2]};
    valid = 1'b1;
    rvc_decompress_rv64 = 32'h0000_0013;

    unique case (c[1:0])
      2'b00: begin
        unique case (c[15:13])
          3'b000: begin // C.ADDI4SPN
            if (c[12:5] == '0) valid = 1'b0;
            else begin
              imm_i = {2'b0, c[10:7], c[12:11], c[5], c[6], 2'b0};
              rvc_decompress_rv64 = enc_i(7'b0010011, 3'b000, rdp, 5'd2, imm_i);
            end
          end
          3'b001: begin // C.FLD
            imm_i = {4'b0, c[6:5], c[12:10], 3'b000};
            rvc_decompress_rv64 = enc_i(7'b0000111, 3'b011, rdp, rs1p, imm_i);
          end
          3'b010: begin // C.LW
            imm_i = {5'b0, c[5], c[12:10], c[6], 2'b00};
            rvc_decompress_rv64 = enc_i(7'b0000011, 3'b010, rdp, rs1p, imm_i);
          end
          3'b011: begin // C.LD
            imm_i = {4'b0, c[6:5], c[12:10], 3'b000};
            rvc_decompress_rv64 = enc_i(7'b0000011, 3'b011, rdp, rs1p, imm_i);
          end
          3'b100: begin // Zcb byte/halfword loads and stores
            unique case (c[12:10])
              3'b000: begin // C.LBU
                imm_i = {10'b0, c[5], c[6]};
                rvc_decompress_rv64 = enc_i(7'b0000011, 3'b100, rdp, rs1p, imm_i);
              end
              3'b001: begin // C.LHU / C.LH
                imm_i = {10'b0, c[5], 1'b0};
                rvc_decompress_rv64 = enc_i(7'b0000011,
                                             c[6] ? 3'b001 : 3'b101,
                                             rdp, rs1p, imm_i);
              end
              3'b010: begin // C.SB
                imm_i = {10'b0, c[5], c[6]};
                rvc_decompress_rv64 = enc_s(7'b0100011, 3'b000,
                                             rs1p, rdp, imm_i);
              end
              3'b011: begin // C.SH (c[6] == 1 is reserved)
                if (c[6] == 1'b0) begin
                  imm_i = {10'b0, c[5], 1'b0};
                  rvc_decompress_rv64 = enc_s(7'b0100011, 3'b001,
                                               rs1p, rdp, imm_i);
                end else begin
                  valid = 1'b0;
                end
              end
              default: valid = 1'b0;
            endcase
          end
          3'b101: begin // C.FSD
            imm_i = {4'b0, c[6:5], c[12:10], 3'b000};
            rvc_decompress_rv64 = enc_s(7'b0100111, 3'b011, rs1p, rdp, imm_i);
          end
          3'b110: begin // C.SW
            imm_i = {5'b0, c[5], c[12:10], c[6], 2'b00};
            rvc_decompress_rv64 = enc_s(7'b0100011, 3'b010, rs1p, rdp, imm_i);
          end
          3'b111: begin // C.SD
            imm_i = {4'b0, c[6:5], c[12:10], 3'b000};
            rvc_decompress_rv64 = enc_s(7'b0100011, 3'b011, rs1p, rdp, imm_i);
          end
          default: valid = 1'b0;
        endcase
      end
      2'b01: begin
        unique case (c[15:13])
          3'b000: begin // C.ADDI / C.NOP
            imm_i = {{6{c[12]}}, c[12], c[6:2]};
            rvc_decompress_rv64 = enc_i(7'b0010011, 3'b000, rd, rd, imm_i);
          end
          3'b001: begin // C.ADDIW (RV64)
            if (rd == '0) valid = 1'b0;
            else begin
              imm_i = {{6{c[12]}}, c[12], c[6:2]};
              rvc_decompress_rv64 = enc_i(7'b0011011, 3'b000, rd, rd, imm_i);
            end
          end
          3'b010: begin // C.LI
            imm_i = {{6{c[12]}}, c[12], c[6:2]};
            rvc_decompress_rv64 = enc_i(7'b0010011, 3'b000, rd, 5'd0, imm_i);
          end
          3'b011: begin
            // Zcmop encodings are architecturally no-ops.  They occupy the
            // otherwise-reserved zero-immediate C.LUI space.
            if (c[12] == 1'b0 && c[6:2] == '0 && c[7] == 1'b1) begin
              rvc_decompress_rv64 = 32'h0000_0013;
            end else if (rd == 5'd2) begin // C.ADDI16SP
              if ({c[12], c[6:2]} == '0) valid = 1'b0;
              else begin
                imm_i = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0};
                rvc_decompress_rv64 = enc_i(7'b0010011, 3'b000, 5'd2, 5'd2, imm_i);
              end
            end else if (rd == '0 || {c[12], c[6:2]} == '0) begin
              valid = 1'b0;
            end else begin // C.LUI
              imm_u = {{14{c[12]}}, c[12], c[6:2]};
              rvc_decompress_rv64 = enc_u(rd, imm_u);
            end
          end
          3'b100: begin
            unique case (c[11:10])
              2'b00: begin // C.SRLI
                imm_i = {6'b000000, c[12], c[6:2]};
                rvc_decompress_rv64 = enc_i(7'b0010011, 3'b101, rs1p, rs1p, imm_i);
              end
              2'b01: begin // C.SRAI
                imm_i = {6'b010000, c[12], c[6:2]};
                rvc_decompress_rv64 = enc_i(7'b0010011, 3'b101, rs1p, rs1p, imm_i);
              end
              2'b10: begin // C.ANDI
                imm_i = {{6{c[12]}}, c[12], c[6:2]};
                rvc_decompress_rv64 = enc_i(7'b0010011, 3'b111, rs1p, rs1p, imm_i);
              end
              2'b11: begin
                if (c[12] == 1'b0) begin
                  unique case (c[6:5])
                    2'b00: rvc_decompress_rv64 = enc_r(7'b0100000, rdp, rs1p, 3'b000, rs1p, 7'b0110011); // C.SUB
                    2'b01: rvc_decompress_rv64 = enc_r(7'b0000000, rdp, rs1p, 3'b100, rs1p, 7'b0110011); // C.XOR
                    2'b10: rvc_decompress_rv64 = enc_r(7'b0000000, rdp, rs1p, 3'b110, rs1p, 7'b0110011); // C.OR
                    2'b11: rvc_decompress_rv64 = enc_r(7'b0000000, rdp, rs1p, 3'b111, rs1p, 7'b0110011); // C.AND
                  endcase
                end else if (c[6] == 1'b0 && c[5] == 1'b0) begin // C.SUBW
                  rvc_decompress_rv64 = enc_r(7'b0100000, rdp, rs1p, 3'b000, rs1p, 7'b0111011);
                end else if (c[6] == 1'b0 && c[5] == 1'b1) begin // C.ADDW
                  rvc_decompress_rv64 = enc_r(7'b0000000, rdp, rs1p, 3'b000, rs1p, 7'b0111011);
                end else if (c[6:5] == 2'b10) begin // C.MUL (Zcb)
                  rvc_decompress_rv64 = enc_r(7'b0000001, rdp, rs1p,
                                               3'b000, rs1p, 7'b0110011);
                end else if (c[6:5] == 2'b11) begin
                  unique case (c[4:2])
                    3'b000: rvc_decompress_rv64 = enc_i(7'b0010011, 3'b111,
                                                         rs1p, rs1p, 12'h0ff); // C.ZEXT.B
                    3'b001: rvc_decompress_rv64 = enc_i(7'b0010011, 3'b001,
                                                         rs1p, rs1p, 12'h604); // C.SEXT.B
                    3'b010: rvc_decompress_rv64 = enc_r(7'b0000100, 5'd0,
                                                         rs1p, 3'b100, rs1p,
                                                         7'b0111011); // C.ZEXT.H
                    3'b011: rvc_decompress_rv64 = enc_i(7'b0010011, 3'b001,
                                                         rs1p, rs1p, 12'h605); // C.SEXT.H
                    3'b100: rvc_decompress_rv64 = enc_r(7'b0000100, 5'd0,
                                                         rs1p, 3'b000, rs1p,
                                                         7'b0111011); // C.ZEXT.W
                    3'b101: rvc_decompress_rv64 = enc_i(7'b0010011, 3'b100,
                                                         rs1p, rs1p, 12'hfff); // C.NOT
                    default: valid = 1'b0;
                  endcase
                end else begin
                  valid = 1'b0;
                end
              end
            endcase
          end
          3'b101: begin // C.J
            imm_j = {{9{c[12]}}, c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
            rvc_decompress_rv64 = enc_j(5'd0, imm_j);
          end
          3'b110: begin // C.BEQZ
            imm_b = {{4{c[12]}}, c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
            rvc_decompress_rv64 = enc_b(3'b000, rs1p, 5'd0, imm_b);
          end
          3'b111: begin // C.BNEZ
            imm_b = {{4{c[12]}}, c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
            rvc_decompress_rv64 = enc_b(3'b001, rs1p, 5'd0, imm_b);
          end
          default: valid = 1'b0;
        endcase
      end
      2'b10: begin
        unique case (c[15:13])
          3'b000: begin // C.SLLI
            imm_i = {6'b000000, c[12], c[6:2]};
            rvc_decompress_rv64 = enc_i(7'b0010011, 3'b001, rd, rd, imm_i);
          end
          3'b001: begin // C.FLDSP
            if (rd == '0) valid = 1'b0;
            else begin
              imm_i = {3'b0, c[4:2], c[12], c[6:5], 3'b000};
              rvc_decompress_rv64 = enc_i(7'b0000111, 3'b011, rd, 5'd2, imm_i);
            end
          end
          3'b010: begin // C.LWSP
            if (rd == '0) valid = 1'b0;
            else begin
              imm_i = {4'b0, c[3:2], c[12], c[6:4], 2'b00};
              rvc_decompress_rv64 = enc_i(7'b0000011, 3'b010, rd, 5'd2, imm_i);
            end
          end
          3'b011: begin // C.LDSP
            if (rd == '0) valid = 1'b0;
            else begin
              imm_i = {3'b0, c[4:2], c[12], c[6:5], 3'b000};
              rvc_decompress_rv64 = enc_i(7'b0000011, 3'b011, rd, 5'd2, imm_i);
            end
          end
          3'b100: begin
            if (c[12] == 1'b0) begin
              if (rs2 == '0) begin // C.JR
                if (rd == '0) valid = 1'b0;
                else rvc_decompress_rv64 = enc_i(7'b1100111, 3'b000, 5'd0, rd, 12'b0);
              end else begin // C.MV
                rvc_decompress_rv64 = enc_r(7'b0000000, rs2, 5'd0, 3'b000, rd, 7'b0110011);
              end
            end else if (rs2 == '0) begin
              if (rd == '0) rvc_decompress_rv64 = 32'h0010_0073; // C.EBREAK
              else rvc_decompress_rv64 = enc_i(7'b1100111, 3'b000, 5'd1, rd, 12'b0); // C.JALR
            end else begin // C.ADD
              rvc_decompress_rv64 = enc_r(7'b0000000, rs2, rd, 3'b000, rd, 7'b0110011);
            end
          end
          3'b101: begin // C.FSDSP
            imm_i = {3'b0, c[9:7], c[12:10], 3'b000};
            rvc_decompress_rv64 = enc_s(7'b0100111, 3'b011, 5'd2, rs2, imm_i);
          end
          3'b110: begin // C.SWSP
            imm_i = {4'b0, c[8:7], c[12:9], 2'b00};
            rvc_decompress_rv64 = enc_s(7'b0100011, 3'b010, 5'd2, rs2, imm_i);
          end
          3'b111: begin // C.SDSP
            imm_i = {3'b0, c[9:7], c[12:10], 3'b000};
            rvc_decompress_rv64 = enc_s(7'b0100011, 3'b011, 5'd2, rs2, imm_i);
          end
          default: valid = 1'b0;
        endcase
      end
      default: valid = 1'b0;
    endcase
  endfunction
endpackage : riscv_rvc_pkg
