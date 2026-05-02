package common_pkg;

  function automatic int unsigned greatest_common_divisor(
    input int unsigned lhs,
    input int unsigned rhs
  );
    int unsigned remainder;
    begin
      while(rhs != 0) begin
        remainder = rhs;
        rhs = lhs % rhs;
        lhs = remainder;
      end
      greatest_common_divisor = lhs;
    end
  endfunction

endpackage
