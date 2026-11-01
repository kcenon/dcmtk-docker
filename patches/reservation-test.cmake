
# Appended only in the builder stage; not installed in the runtime image.
add_executable(filename-reservation-test /patches/test-filename-reservation.cc)
target_link_libraries(filename-reservation-test dcmqrdb dcmnet dcmdata oflog ofstd)
target_include_directories(filename-reservation-test PRIVATE
    ${CMAKE_BINARY_DIR}/config/include
    ${CMAKE_SOURCE_DIR}/dcmqrdb/include
    ${CMAKE_SOURCE_DIR}/dcmnet/include
    ${CMAKE_SOURCE_DIR}/dcmdata/include
    ${CMAKE_SOURCE_DIR}/oflog/include
    ${CMAKE_SOURCE_DIR}/ofstd/include)
