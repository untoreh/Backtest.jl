import Base.display

abstract type ContiguityException <: Exception end

struct RightContiguityException <: ContiguityException
    stored_date::AbstractDateTime
    new_date::AbstractDateTime
end

display(e::RightContiguityException) = "Data stored ends at $(e.stored_date) while new data starts at $(e.new_date)."
show(e::RightContiguityException) = display(e)

struct LeftContiguityException <: Exception
    stored_date::AbstractDateTime
    new_date::AbstractDateTime
end

display(e::LeftContiguityException) = "Data stored starts at $(e.stored_date) while new data ends at $(e.new_date)."
show(e::LeftContiguityException) = display(e)
