//只是放在这里，还没有研究fft的输入输出
//如果需要单独把 init 函数和 destroy 函数抽出来，我再到调用的地方加
//https://github.com/qzwlecr/CESM/issues/12
#include <cufft.h>
#include <stdio.h>
#include <fstream>
#include <thrust/transform.h>
#include <thrust/functional.h>
#include <iostream>
#include <string>
#include <unordered_map>
#include <vector>

#include <cuda.h>
#include <assert.h>
#include <cuda_runtime_api.h>
#include <chrono>
using namespace std::chrono;
#define DOG_BUGGY 0

class ErrorDetect {
  public:
    ErrorDetect(int line) : line(line) {}
    int line;
};

#define ED ErrorDetect(__LINE__)

static void operator<<(const ErrorDetect& detect, cudaError_t error) {
    if(error) {
        fprintf(stderr, "{{{error %d at line %d}}}", (int)error, detect.line);
        assert(false);
    }
    return;
}
static void operator<<(const ErrorDetect& detect, cufftResult_t error) {
    if(error) {
        fprintf(stderr, "{{{error %d at line %d}}}", (int)error, detect.line);
        assert(false);
    }
    return;
}

extern "C" void needle_(                      //
    double* a_,                               // inout, elements[lot][N+2]
    int* batch_size_, int* batch_distance_    // distance
) {
    static int counter = 0;
    printf("[needle at %p, size=%d, dist=%d]", a_, *batch_size_, *batch_distance_);
    ++counter;
    auto current_time = system_clock::now();
    auto path = "/home/mike/tmp/";
    auto filename = path + std::to_string(system_clock::to_time_t(current_time)) + "-" +
                    std::to_string(counter) + ".dat";
    int data_byte = *batch_distance_ * *batch_size_ * sizeof(double);
    std::ofstream fout(filename, std::ios::binary);
    fout.write((char*)a_, data_byte);
}

template <typename T, bool is_managed = false>
T* cuda_alloc(int size) {
    int bytes = sizeof(T) * size;
    T* tmp;
    if(is_managed) {
        cudaMallocManaged(&tmp, bytes);
    } else {
        cudaMalloc(&tmp, bytes);
    }
    return tmp;
}

// blocks: y_dim
// threads: x_dim
// s_ should be constant array

// need adjustment
constexpr int MAX_S_SIZE = 128 + 16;
struct PftRecord {
    // here is the wtf
    int s_size;
    int x_dim;
    double s_rev[MAX_S_SIZE];
    int fft_count;
    int encode_ids[MAX_S_SIZE];
    int decode_ids[MAX_S_SIZE];
    int fwd_plan, bck_plan;
    double* dev_damp;                // of fft_count * (x_dim + 2), keep it in memory
    cufftDoubleReal* dev_origin;     // of fft_count * (x_dim), keep it in memory
    cufftDoubleComplex* dev_freq;    // of fft_count * (x_dim + 2), keep it in memory
    double* dev_inout;               // of s_size * x_dim
};

thread_local PftRecord pft_records[4] = {};
// static __constant__ PftRecord dev_pft_records[4];

extern "C"    //
    void
    cuda_pft_cf_record_(int* plan_id_, double* s_, int* s_beg_, int* s_end_,
                        double* damp_, int* im_, int* fft_flt_) {
    // initalize this region for further call
    int plan_id = *plan_id_;
    assert(plan_id >= 0 && plan_id < 4);
    int s_size = *s_end_ - *s_beg_ + 1;
    assert(s_size < MAX_S_SIZE);
    int x_dim = *im_;
    auto& record = pft_records[plan_id];
    auto* encode_ids = record.encode_ids;
    auto* decode_ids = record.decode_ids;

    int fft_count = 0;

    bool force_fft = (bool)*fft_flt_;
    for(int i = 0; i < s_size; ++i) {
        auto coef = s_[i];
        record.s_rev[i] = 1.0 / coef;
        if(coef <= 1.01) {
            // skip
            encode_ids[i] = -2;
        } else if(!force_fft && coef <= 4.0) {
            // shortcut
            encode_ids[i] = -1;
        } else {
            // real fft
            int id = fft_count;
            ++fft_count;
            encode_ids[i] = id;
            decode_ids[id] = i;
        }
    }
    if(DOG_BUGGY) {
        printf("\nplan<%d>\n", plan_id);
        for(int i = 0; i < fft_count; ++i) {
            printf("$%d ", decode_ids[i]);
        }
        printf("\n");
        for(int i = 0; i < s_size; ++i) {
            printf("#%d ", encode_ids[i]);
        }
        printf("\n");
        fflush(stdout);
    }
    record.s_size = s_size;
    if(record.x_dim == x_dim && record.fft_count == fft_count) {
        // well done
        // do nothing
    } else {
        if(record.dev_damp || record.dev_origin || record.dev_freq) {
            assert(false);
            cudaFree(record.dev_damp);
            cudaFree(record.dev_origin);
            cudaFree(record.dev_freq);
            cudaFree(record.dev_inout);
            cufftDestroy(record.fwd_plan);
            cufftDestroy(record.bck_plan);
        }
        record.x_dim = x_dim;
        record.fft_count = fft_count;
        record.dev_damp = cuda_alloc<double>(fft_count * (x_dim + 2));
        record.dev_origin = cuda_alloc<double>(fft_count * x_dim);
        record.dev_freq = cuda_alloc<cufftDoubleComplex>(fft_count * (x_dim + 2) / 2);
        record.dev_inout = cuda_alloc<double>(s_size * x_dim);

        ED << cufftPlan1d(&record.fwd_plan, x_dim, CUFFT_D2Z, fft_count);
        ED << cufftPlan1d(&record.bck_plan, x_dim, CUFFT_Z2D, fft_count);
    }
    double placeholder[4] = {1.0, 1.0, 1.0, 1.0};
    for(int id = 0; id < fft_count; id++) {
        int i = decode_ids[id];
        double* dev_damp_ptr = record.dev_damp + id * (x_dim + 2);
        double* host_damp_ptr = damp_ + i * x_dim;
        // set damp
        ED << cudaMemcpy(dev_damp_ptr, placeholder, sizeof(placeholder),
                         cudaMemcpyHostToDevice);
        ED << cudaMemcpy(dev_damp_ptr + 4, host_damp_ptr + 2,
                         sizeof(double) * (x_dim - 2), cudaMemcpyHostToDevice);
    }
    // ED << cudaMemcpyToSymbol(dev_pft_records, pft_records, 4 * sizeof(PftRecord));
}

__global__ void pft_prepare(double* __restrict__ p_inout, PftRecord record) {
    int s_index = blockIdx.x;
    int x_id = threadIdx.x;
    // auto& record = dev_pft_records[plan_id];
    int x_dim = record.x_dim;
    int id = record.encode_ids[s_index];
    double* raw_p = p_inout + s_index * x_dim;
    if(id == -2 || x_id >= x_dim) {
        // do nothing
    } else if(id == -1) {
        // inplace filter
        double s_rev = record.s_rev[s_index];
        double mid = raw_p[x_id];
        double left = x_id - 1 >= 0 ? raw_p[x_id - 1] : raw_p[x_dim];
        double right = x_id + 1 < x_dim ? raw_p[x_id + 1] : raw_p[0];
        double result = mid * s_rev + (1 - s_rev) * 0.5 * (left + right);
        __syncthreads();
        raw_p[x_id] = result;
    } else {
        // fft
        int fft_id = id;
        // fill into destination
        double* dest = record.dev_origin + fft_id * x_dim;
        dest[x_id] = raw_p[x_id];
    }
}

__global__ void pft_finish(double* __restrict__ p_inout, PftRecord record) {
    int fft_id = blockIdx.x;
    // auto& record = dev_pft_records[plan_id];
    int x_dim = record.x_dim;
    int s_index = record.decode_ids[fft_id];
    double* src = record.dev_origin + fft_id * x_dim;
    double* dest = p_inout + s_index * x_dim;

    int x_id = threadIdx.x;
    if(x_id < x_dim) {
        dest[x_id] = src[x_id];
    }
}

#include <vector>
using std::vector;
void log_freq(PftRecord& record, double* arr_) {
    int stride = record.x_dim + 2;
    for(int i = 0; i < 1; ++i) {
        vector<double> arr(stride);
        cudaMemcpy(arr.data(), arr_ + i * stride, sizeof(double)*stride, cudaMemcpyDeviceToHost);
        for(int j = 0; j < stride; ++j) {
            printf("%.6lf\t", arr[j]);
        }
        printf("freq\n");
    }
    fflush(stdout);
}

void log_origin(PftRecord& record, double* arr_) {
    int stride = record.x_dim;
    for(int i = 0; i < 1; ++i) {
        vector<double> arr(stride);
        cudaMemcpy(arr.data(), arr_ + i * stride, sizeof(double)*stride, cudaMemcpyDeviceToHost);
        for(int j = 0; j < stride; ++j) {
            printf("%.6lf\t", arr[j]);
        }
        printf("origin\n");
    }
    fflush(stdout);
}

void log_raw(PftRecord& record, double* arr_) {
    int stride = record.x_dim;
    for(int i = 0; i < 1; ++i) {
        int id = record.encode_ids[i];
        vector<double> arr(stride);
        cudaMemcpy(arr.data(), arr_ + id * stride, sizeof(double)*stride, cudaMemcpyDeviceToHost);
        for(int j = 0; j < stride; ++j) {
            printf("%.6lf\t", arr[j]);
        }
        printf("raw[%d]\n", id);
    }
    fflush(stdout);
}

extern "C" void cuda_pft2d_(double* p_inout_,    // array filtered [y_dim][x_dim]
                            int* plan_id_,       //
                            // raw datas
                            double* xxx_s, double* xxx_d,    //
                            int* xxx_im, int* xxx_jp         //
) {
    int plan_id = *plan_id_;
    auto& record = pft_records[plan_id];
    if(DOG_BUGGY) {
        // PftRecord mirror;
        // cudaMemcpyFromSymbol(&mirror, dev_pft_records, sizeof(PftRecord));
        // record = mirror;
    }
    int s_size = record.s_size;
    int x_dim = record.x_dim;
    assert(x_dim == 144);
    int fft_count = record.fft_count;
    auto* dev_damp = record.dev_damp;
    auto* dev_origin = record.dev_origin;
    auto* dev_freq = record.dev_freq;
    auto* dev_inout = record.dev_inout;
    if(DOG_BUGGY) {    // tester
        assert(*xxx_im == x_dim);
        assert(*xxx_jp == s_size);
        double wtf = xxx_s[14] - 1.0 / record.s_rev[14];
        assert((float)(wtf) == (float)0.0);
        double the_fuck[146];
        int id = 14;
        int index = record.decode_ids[id];
        ED << cudaMemcpy(the_fuck, dev_damp + id * (x_dim + 2),
                         sizeof(double) * (x_dim + 2), cudaMemcpyDeviceToHost);
        double* ref = xxx_d + index * x_dim;
        for(int i = 4; i < 146; ++i) {
            assert(ref[i - 2] == the_fuck[i]);
        }
        assert(the_fuck[0] == 1.0);
        assert(the_fuck[1] == 1.0);
        assert(the_fuck[2] == 1.0);
        assert(the_fuck[3] == 1.0);
    }
    // what about d?
    ED << cudaMemcpy(dev_inout, p_inout_, sizeof(double) * s_size * x_dim,
                     cudaMemcpyHostToDevice);
    // may change to benifit the hardware
    // log_raw(record, dev_inout);
    // assert(false);
    pft_prepare<<<s_size, x_dim>>>(dev_inout, record);

    // ED << cufftExecD2Z(record.fwd_plan, dev_origin, dev_freq);


    // thrust::transform(thrust::system::cuda::par,
    //                   (double*)dev_freq,                              //
    //                   (double*)dev_freq + fft_count * (x_dim + 2),    //
    //                   dev_damp,                                       //
    //                   (double*)dev_freq,                              //
    //                   [] __device__(double a, double b) { return a / 144.0; });
    // // log_freq(record, (double*)dev_freq); 
    // // assert(false);
    // ED << cufftExecZ2D(record.bck_plan, dev_freq, dev_origin);
    pft_finish<<<s_size, x_dim>>>(dev_inout, record);
    ED << cudaMemcpy(p_inout_, dev_inout, sizeof(double) * s_size * x_dim,
                     cudaMemcpyDeviceToHost);
    if(DOG_BUGGY) {
        printf("\n{{final_data\n");

        printf("}}\n");
        fflush(stdout);
        assert(false);
    }
}
