# Author: Lars Buitinck
# License: BSD 3 clause

import sys
import array
cimport cython
from libc.stdlib cimport abs
from libcpp.vector cimport vector

cimport numpy as np
import numpy as np
from ..utils._typedefs cimport INT32TYPE_t, INT64TYPE_t
from ..utils.murmurhash cimport murmurhash3_bytes_s32
from ..utils._vector_sentinel cimport vector_to_nd_array

np.import_array()


def transform(raw_X, Py_ssize_t n_features, dtype,
              bint alternate_sign=1, unsigned int seed=0):
    """Guts of FeatureHasher.transform.

    Returns
    -------
    n_samples : integer
    indices, indptr, values : lists
        For constructing a scipy.sparse.csr_matrix.

    """
    cdef INT32TYPE_t h
    cdef double value

    cdef vector[INT32TYPE_t] indices
    cdef vector[INT64TYPE_t] indptr
    indptr.push_back(0)

    # Since Python array does not understand Numpy dtypes, we grow the indices
    # and values arrays ourselves. Use a Py_ssize_t capacity for safety.
    cdef Py_ssize_t capacity = 8192     # arbitrary
    cdef np.int64_t size = 0
    cdef np.ndarray values = np.empty(capacity, dtype=dtype)

    for x in raw_X:
        for f, v in x:
            if isinstance(v, (str, unicode)):
                f = "%s%s%s" % (f, '=', v)
                value = 1
            else:
                value = v

            if value == 0:
                continue

            if isinstance(f, unicode):
                f = (<unicode>f).encode("utf-8")
            # Need explicit type check because Murmurhash does not propagate
            # all exceptions. Add "except *" there?
            elif not isinstance(f, bytes):
                raise TypeError("feature names must be strings")

            h = murmurhash3_bytes_s32(<bytes>f, seed)

            if h == - 2147483648:
                # abs(-2**31) is undefined behavior because h is a `np.int32`
                # The following is defined such that it is equal to: abs(-2**31) % n_features
                indices.push_back((2147483647 - (n_features - 1)) % n_features)
            else:
                indices.push_back(abs(h) % n_features)
            # improve inner product preservation in the hashed space
            if alternate_sign:
                value *= (h >= 0) * 2 - 1
            values[size] = value
            size += 1

            if size == capacity:
                capacity *= 2
                # can't use resize member because there might be multiple
                # references to the arrays due to Cython's error checking
                values = np.resize(values, capacity)

        indptr.push_back(size)

    indicies_array = vector_to_nd_array(&indices)
    indptr_array = vector_to_nd_array(&indptr)

    if indptr_array[indptr_array.shape[0]-1] > np.iinfo(np.int32).max:  # = 2**31 - 1
        # both indices and indptr have the same dtype in CSR arrays
        indicies_array = indicies_array.astype(np.int64, copy=False)
    else:
        indptr_array = indptr_array.astype(np.int32, copy=False)

    return (indicies_array, indptr_array, values[:size])
