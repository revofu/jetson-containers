# Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

ARG BASE_IMAGE=nvcr.io/nvidia/l4t-base:r32.4.4
ARG PYTORCH_IMAGE
ARG TENSORFLOW_IMAGE

FROM ${PYTORCH_IMAGE} as pytorch
FROM ${TENSORFLOW_IMAGE} as tensorflow
FROM ${BASE_IMAGE}


#
# setup environment
#
ENV DEBIAN_FRONTEND=noninteractive
ENV CUDA_HOME="/usr/local/cuda"
ENV PATH="/usr/local/cuda/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"
ENV LLVM_CONFIG="/usr/bin/llvm-config-9"

ARG MAKEFLAGS=-j$(nproc) 
ARG PYTHON3_VERSION=3.8

RUN printenv

    
    
#
# apt packages
#
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
          python3-pip \
		python3-dev \
		python3-matplotlib \
		build-essential \
		gfortran \
		git \
		cmake \
		curl \
		nano \
		libopenblas-dev \
		liblapack-dev \
		libblas-dev \
		libhdf5-serial-dev \
		hdf5-tools \
		libhdf5-dev \
		zlib1g-dev \
		zip \
		libjpeg8-dev \
		libopenmpi3 \
		openmpi-bin \
		openmpi-common \
		protobuf-compiler \
		libprotoc-dev \
		llvm-9 \
		llvm-9-dev \
		libffi-dev \
		libsndfile1 \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean


#
# pull protobuf-cpp from TF container
#
ENV PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=cpp

COPY --from=tensorflow /usr/local/bin/protoc /usr/local/bin
COPY --from=tensorflow /usr/local/lib/libproto* /usr/local/lib/
COPY --from=tensorflow /usr/local/include/google /usr/local/include/google


#
# python packages from TF/PyTorch containers
# note:  this is done in this order bc TF has some specific version dependencies
#
COPY --from=pytorch /usr/local/lib/python2.7/dist-packages/ /usr/local/lib/python2.7/dist-packages/
COPY --from=pytorch /usr/local/lib/python${PYTHON3_VERSION}/dist-packages/ /usr/local/lib/python${PYTHON3_VERSION}/dist-packages/

COPY --from=tensorflow /usr/local/lib/python2.7/dist-packages/ /usr/local/lib/python2.7/dist-packages/
COPY --from=tensorflow /usr/local/lib/python${PYTHON3_VERSION}/dist-packages/ /usr/local/lib/python${PYTHON3_VERSION}/dist-packages/


#
# python pip packages
#
RUN pip3 install --no-cache-dir --ignore-installed pybind11 
RUN pip3 install --no-cache-dir --verbose onnx
RUN pip3 install --no-cache-dir --verbose scipy
RUN pip3 install --no-cache-dir --verbose scikit-learn
RUN pip3 install --no-cache-dir --verbose pandas
RUN pip3 install --no-cache-dir --verbose pycuda
RUN pip3 install --no-cache-dir --verbose numba


#
# CuPy
#
ARG CUPY_VERSION=main
ARG CUPY_NVCC_GENERATE_CODE="arch=compute_53,code=sm_53;arch=compute_62,code=sm_62;arch=compute_72,code=sm_72;arch=compute_87,code=sm_87"

RUN git clone --branch ${CUPY_VERSION} --depth 1 --recursive https://github.com/cupy/cupy cupy && \
    cd cupy && \
    pip3 install --no-cache-dir fastrlock && \
    python3 setup.py install --verbose && \
    cd ../ && \
    rm -rf cupy


#
# PyCUDA
#
RUN pip3 uninstall -y pycuda
RUN pip3 install --no-cache-dir --verbose pycuda six


# 
# install OpenCV (with CUDA)
#
ARG OPENCV_URL=https://nvidia.box.com/shared/static/5v89u6g5rb62fpz4lh0rz531ajo2t5ef.gz
ARG OPENCV_DEB=OpenCV-4.5.0-aarch64.tar.gz

COPY scripts/opencv_install.sh /tmp/opencv_install.sh
RUN cd /tmp && ./opencv_install.sh ${OPENCV_URL} ${OPENCV_DEB}


#
# transformers/diffusers (avoid it changing package versions)
# also, xformers needs TORCH_CUDA_ARCH_LIST set to build the kernels
#
RUN export TORCH_CUDA_ARCH_LIST=$(python3 -c 'import torch; print(";".join([str(float(x.lstrip("sm_"))/10) for x in torch.cuda.get_arch_list()]));') && \
    echo "TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST" && \
    pip3 freeze > /tmp/constraints.txt && \
    pip3 install --no-cache-dir --verbose \
	xformers \
	transformers \
	diffusers \
	optimum[exporters,onnxruntime] \
	--constraint /tmp/constraints.txt && \
    rm /tmp/constraints.txt
    
    
#
# upgrade cmake (required to build onnxruntime)
#
RUN pip3 install --upgrade --force-reinstall --no-cache-dir --verbose cmake && \
    cmake --version && \
    which cmake


#
# onnxruntime (https://onnxruntime.ai/docs/build/eps.html#nvidia-jetson-tx1tx2nanoxavier)
#
ARG ONNXRUNTIME_VERSION=main

RUN pip3 uninstall -y onnxruntime && \
    git clone --branch ${ONNXRUNTIME_VERSION} --depth 1 --recursive https://github.com/microsoft/onnxruntime /tmp/onnxruntime && \
    cd /tmp/onnxruntime && \
    ./build.sh --config Release --update --build --parallel --build_wheel --allow_running_as_root \
        --cmake_extra_defines CMAKE_CXX_FLAGS="-Wno-unused-variable" \
        --cuda_home /usr/local/cuda --cudnn_home /usr/lib/aarch64-linux-gnu \
        --use_tensorrt --tensorrt_home /usr/lib/aarch64-linux-gnu && \
    cd build/Linux/Release && \
    make install && \
    pip3 install --no-cache-dir --verbose dist/onnxruntime_gpu-*.whl && \
    rm -rf /tmp/onnxruntime
	

#
# NeMo (needs more recent OpenFST than focal apt)
#
ARG FST_VERSION=1.8.2
RUN cd /tmp && \
    wget --quiet --show-progress --progress=bar:force:noscroll --no-check-certificate https://www.openfst.org/twiki/pub/FST/FstDownload/openfst-${FST_VERSION}.tar.gz && \
    tar -xzvf openfst-${FST_VERSION}.tar.gz && \
    cd openfst-${FST_VERSION} && \
    ./configure --enable-grm && \
    make -j$(nproc) && \
    make install && \
    cd ../ && \
    rm -rf openfst
    
# install nemo_toolkit
RUN pip3 install --no-cache-dir --verbose nemo_toolkit['all']

# libopencc.so.1 needed by: nemo/collections/common/tokenizers/chinese_tokenizers.py
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
          libopencc-dev \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean
    
# patch for: cannot import name 'GradBucket' from 'torch.distributed'
RUN NEMO_PATH="$(pip3 show nemo_toolkit | grep Location: | cut -d' ' -f2)/nemo" && \
    sed -i '/from torch.distributed.algorithms.ddp_comm_hooks.debugging_hooks import noop_hook/d' $NEMO_PATH/collections/nlp/parts/nlp_overrides.py


#
# install rust (used by Jupyter)
# 
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustc --version && \
    pip3 install setuptools-rust
    
    
#
# JupyterLab
#
RUN pip3 install --no-cache-dir --verbose jupyter jupyterlab && \
    pip3 install --no-cache-dir --verbose jupyterlab_widgets
    
RUN jupyter lab --generate-config
RUN python3 -c "from notebook.auth.security import set_password; set_password('nvidia', '/root/.jupyter/jupyter_notebook_config.json')"

CMD /bin/bash -c "jupyter lab --ip 0.0.0.0 --port 8888 --allow-root &> /var/log/jupyter.log" & \
	echo "allow 10 sec for JupyterLab to start @ http://$(hostname -I | cut -d' ' -f1):8888 (password nvidia)" && \
	echo "JupterLab logging location:  /var/log/jupyter.log  (inside the container)" && \
	/bin/bash


# vulnerability fixed in: 0.18.3 (GHSA-v3c5-jqr6-7qm8 - https://github.com/advisories/GHSA-v3c5-jqr6-7qm8)
RUN pip3 install --upgrade --verbose future && \
    pip3 show future
    
# workaround for "cannot allocate memory in static TLS block"
ENV LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libgomp.so.1:/usr/local/lib/python${PYTHON3_VERSION}/dist-packages/sklearn/__check_build/../../scikit_learn.libs/libgomp-d22c30c5.so.1.0.0

# ImportError: `onnxruntime-gpu` is installed, but GPU dependencies are not loaded.
RUN sed -i 's/if "ORT_CUDA" not in file_string or "ORT_TENSORRT" not in file_string:/if False:/g' /usr/local/lib/python${PYTHON3_VERSION}/dist-packages/optimum/onnxruntime/utils.py


